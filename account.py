"""
Deleting your account (Profile -> Delete account; the App Store requires it). Everything that's about you goes; things
you shared with other people stay theirs, without you in them:

  - your profile, friend list (both sides), friend ID, requests, private doc, live location: deleted
  - your posts, your comments everywhere, your likes and ratings: deleted
  - plans you made: handed to someone else who's going (with their chat); if nobody else is going, deleted.
    On other people's plans you're taken off and your chat messages are deleted
  - group photos you posted with other people in them: kept for them, posted by one of them now, without you.
    Just you in it: deleted
  - chats: your messages are deleted. A 1:1 chat stays for the other person, with you shown as "Deleted user";
    you leave group chats
"""
from google.cloud.firestore_v1 import ArrayRemove, ArrayUnion, DELETE_FIELD
from google.cloud.firestore_v1.base_query import FieldFilter

PER_PERSON = ("rsvp", "names", "alerts", "travel", "arrivals", "origins", "modes")  # hangout maps keyed by uid


def _where(db, col, field, op, value):
    return db.collection(col).where(filter=FieldFilter(field, op, value)).stream()


def _wipe(ref):
    """A document and its subcollections (a hangout's chat and live locations, a chat's messages)."""
    for sub in ref.collections():
        for d in sub.stream():
            d.reference.delete()
    ref.delete()


def _my_messages(ref, uid):
    for m in ref.collection("messages").where(filter=FieldFilter("from", "==", uid)).stream():
        m.reference.delete()


def delete_account(db, uid):
    """Everything above, then the sign-in itself. Safe to run again if it stopped halfway."""
    from firebase_admin import auth
    me = db.collection("users").document(uid)
    profile = (me.get().to_dict() or {})

    # friends, both sides
    for f in me.collection("friends").stream():
        db.collection("users").document(f.id).collection("friends").document(uid).delete()
        f.reference.delete()
    for field in ("from", "to"):
        for r in _where(db, "requests", field, "==", uid):
            r.reference.delete()
    for c in _where(db, "codes", "uid", "==", uid):
        c.reference.delete()

    # plans: yours go to someone else who's going, so their plan (and its chat) doesn't vanish
    seen = set()
    for field in ("attendees", "invited"):
        for h in _where(db, "hangouts", field, "array_contains", uid):
            if h.id in seen:
                continue
            seen.add(h.id)
            data = h.to_dict() or {}
            going = [u for u in data.get("attendees") or [] if u != uid]
            if data.get("createdBy") == uid and not going:
                _wipe(h.reference)
                continue
            _my_messages(h.reference, uid)
            h.reference.collection("where").document(uid).delete()
            h.reference.update({"attendees": ArrayRemove([uid]), "invited": ArrayRemove([uid]),
                                **({"createdBy": going[0]} if data.get("createdBy") == uid else {}),
                                **{f"{k}.{uid}": DELETE_FIELD for k in PER_PERSON}})

    # group photos: kept for the other people in them, posted by one of them now
    for m in _where(db, "memories", "members", "array_contains", uid):
        data = m.to_dict() or {}
        others = [u for u in data.get("members") or [] if u != uid]
        if data.get("by") == uid and not others:
            m.reference.delete()
            continue
        m.reference.update({"members": ArrayRemove([uid]), f"names.{uid}": DELETE_FIELD,
                            **({"by": others[0], "byName": (data.get("names") or {}).get(others[0], "")} if data.get("by") == uid else {})})
    for p in _where(db, "feed", "viewers", "array_contains", uid):
        data = p.to_dict() or {}
        others = [u for u in data.get("members") or [] if u != uid]
        mine = data.get("by") == uid
        if mine and (data.get("kind") == "post" or not others):
            _wipe(p.reference)  # your own post, with its comments
            continue
        for c in p.reference.collection("comments").where(filter=FieldFilter("from", "==", uid)).stream():
            c.reference.delete()
        p.reference.update({"members": ArrayRemove([uid]), "viewers": ArrayRemove([uid]), "likes": ArrayRemove([uid]),
                            "tagged": ArrayRemove([uid]), f"names.{uid}": DELETE_FIELD, f"handles.{uid}": DELETE_FIELD,
                            f"ratings.{uid}": DELETE_FIELD, f"late.{uid}": DELETE_FIELD,
                            **({"by": others[0], "byName": (data.get("names") or {}).get(others[0], "")} if mine else {})})

    # chats: your messages go; a 1:1 chat stays for the other person (you show as "Deleted user"); you leave groups
    for c in _where(db, "chats", "members", "array_contains", uid):
        data = c.to_dict() or {}
        _my_messages(c.reference, uid)
        left = list(c.reference.collection("messages").order_by("at", direction="DESCENDING").limit(1).stream())
        if not data.get("group") and not left:
            _wipe(c.reference)  # nothing of theirs in it either
            continue
        last = left[0].to_dict() if left else DELETE_FIELD
        change = {f"photos.{uid}": DELETE_FIELD, f"read.{uid}": DELETE_FIELD,
                  **({"last": last} if (data.get("last") or {}).get("from") == uid else {})}
        if data.get("group"):
            change.update({"members": ArrayRemove([uid]), f"names.{uid}": DELETE_FIELD})
        else:
            change.update({f"names.{uid}": "Deleted user", "gone": ArrayUnion([uid])})
        c.reference.update(change)

    # you
    if profile.get("code"):
        db.collection("codes").document(profile["code"]).delete()
    db.collection("private").document(uid).delete()
    db.collection("locations").document(uid).delete()
    db.collection("publicProfiles").document(uid).delete()
    _wipe(me)
    try:
        auth.delete_user(uid)
    except auth.UserNotFoundError:
        pass
