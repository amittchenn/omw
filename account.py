"""
Deleting your account (Profile -> Delete account; the App Store requires it). Removes your sign-in and everything that's
yours in Firestore, and takes you out of everything you shared with others:

  - your profile, friend list (both sides), friend ID, requests, private doc, live location
  - plans you made, with their chat; on other people's plans you're taken off and your chat messages are deleted
  - group photos and feed posts you posted; on others' you're taken off (and your likes and ratings go)
  - DMs and group chats: you leave them and your messages are deleted
"""
from google.cloud.firestore_v1 import ArrayRemove, DELETE_FIELD
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

    # plans
    seen = set()
    for field in ("attendees", "invited"):
        for h in _where(db, "hangouts", field, "array_contains", uid):
            if h.id in seen:
                continue
            seen.add(h.id)
            if (h.to_dict() or {}).get("createdBy") == uid:
                _wipe(h.reference)
            else:
                _my_messages(h.reference, uid)
                h.reference.collection("where").document(uid).delete()
                h.reference.update({"attendees": ArrayRemove([uid]), "invited": ArrayRemove([uid]),
                                    **{f"{k}.{uid}": DELETE_FIELD for k in PER_PERSON}})

    # photos
    for m in _where(db, "memories", "members", "array_contains", uid):
        if (m.to_dict() or {}).get("by") == uid:
            m.reference.delete()
        else:
            m.reference.update({"members": ArrayRemove([uid]), f"names.{uid}": DELETE_FIELD})
    for p in _where(db, "feed", "viewers", "array_contains", uid):
        if (p.to_dict() or {}).get("by") == uid:
            p.reference.delete()
        else:
            p.reference.update({"members": ArrayRemove([uid]), "viewers": ArrayRemove([uid]), "likes": ArrayRemove([uid]),
                                f"names.{uid}": DELETE_FIELD, f"ratings.{uid}": DELETE_FIELD, f"late.{uid}": DELETE_FIELD})

    # chats
    for c in _where(db, "chats", "members", "array_contains", uid):
        members = (c.to_dict() or {}).get("members") or []
        if len([u for u in members if u != uid]) <= 1 and not (c.to_dict() or {}).get("group"):
            _wipe(c.reference)  # a DM: nothing left to keep
        else:
            _my_messages(c.reference, uid)
            c.reference.update({"members": ArrayRemove([uid]), f"names.{uid}": DELETE_FIELD, f"photos.{uid}": DELETE_FIELD})

    # you
    if profile.get("code"):
        db.collection("codes").document(profile["code"]).delete()
    db.collection("private").document(uid).delete()
    db.collection("locations").document(uid).delete()
    _wipe(me)
    try:
        auth.delete_user(uid)
    except auth.UserNotFoundError:
        pass
