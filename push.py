"""
Push notifications for the iPhone app (Firebase Cloud Messaging -> APNs).

What gets sent:
  - "Time to leave": at each person's leave-now alert (hangouts/{id}.alerts[uid]), unless they've already arrived
  - invites ("Priya invited you to ..."), and "Sam is in" to whoever planned it
  - Live Activity updates (the Dynamic Island while you head there): who's arrived, your leave time, and "end" once everyone's in
  - new chat messages, in a hangout's group chat (hangouts/{id}/messages) and in DMs / group chats (chats/{id}/messages),
    including the automatic "running late" and "arrived" ones

Phones keep their tokens on private/{uid}.pushTokens (web/push.js). Tokens that stop working are removed.
Only runs where PUSH_ENABLED=1 (set it on the one live server), so a laptop or an old deploy never sends duplicates.
"""
import os
import threading
import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

ENABLED = os.getenv("PUSH_ENABLED") == "1"
ALERT_GRACE = timedelta(minutes=10)   # a leave-now alert this late is still worth sending (e.g. after a restart)
FRESH = timedelta(minutes=3)          # older messages than this aren't pushed (they were missed, not new)

_db = None
_hangouts = {}       # id -> latest hangout data (from the listener)
_started = False


def _now():
    return datetime.now(timezone.utc)


def _parse(iso):
    try:
        t = datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
        return t if t.tzinfo else t.replace(tzinfo=timezone.utc)
    except Exception:
        return None


def _local_time(h, iso):
    t = _parse(iso)
    if not t:
        return ""
    t = t.astimezone(ZoneInfo(h.get("tz") or "America/New_York"))
    return t.strftime("%-I:%M %p").replace(":00 ", " ")


def _name(h, uid):
    return (h.get("names") or {}).get(uid) or "A friend"


# ---------- sending ----------
def _tokens(uids):
    """{token: uid} for everyone in uids who has the app with notifications on."""
    out = {}
    uids = [u for u in set(uids) if u]
    if not uids:
        return out
    refs = [_db.collection("private").document(u) for u in uids]
    for snap in _db.get_all(refs):
        for t in (snap.to_dict() or {}).get("pushTokens", []) if snap.exists else []:
            out[t] = snap.id
    return out


def send(uids, title, body, data=None):
    """Notify these people on every phone they've signed in on. Returns how many phones it reached."""
    from firebase_admin import messaging
    from google.cloud.firestore_v1 import ArrayRemove
    owners = _tokens(uids)
    if not owners:
        return 0
    tokens = list(owners)
    msg = messaging.MulticastMessage(
        tokens=tokens,
        notification=messaging.Notification(title=title[:120], body=body[:240]),
        data={k: str(v) for k, v in (data or {}).items()},
        apns=messaging.APNSConfig(payload=messaging.APNSPayload(aps=messaging.Aps(sound="default"))),
    )
    sent = 0
    for i in range(0, len(tokens), 500):  # FCM takes at most 500 tokens per call
        part = messaging.MulticastMessage(tokens=tokens[i:i + 500], notification=msg.notification, data=msg.data, apns=msg.apns)
        res = messaging.send_each_for_multicast(part)
        sent += res.success_count
        for tok, r in zip(part.tokens, res.responses):
            if not r.success and type(r.exception).__name__ in ("UnregisteredError", "SenderIdMismatchError", "InvalidArgumentError"):
                try:  # that phone uninstalled the app or signed out: forget the token
                    _db.collection("private").document(owners[tok]).update({"pushTokens": ArrayRemove([tok])})
                except Exception:
                    pass
    return sent


def _safe(fn, *a):
    try:
        fn(*a)
    except Exception as e:
        print(f"[push] {fn.__name__}: {e}")


# ---------- Live Activities: the Dynamic Island and lock screen (web/island.js starts them, this keeps them current) ----------
def _live_state(h, uid):  # the same numbers web/island.js sends (keep them in step)
    att, arr = h.get("attendees") or [], h.get("arrivals") or {}
    start = _parse(h.get("start"))
    leave = _parse((h.get("alerts") or {}).get(uid)) or start - timedelta(minutes=30)
    others = sorted((u for u in att if u != uid and arr.get(u)), key=lambda u: arr[u], reverse=True)
    return {"leaveAt": leave.timestamp(), "startAt": start.timestamp(), "here": sum(1 for u in att if arr.get(u)),
            "total": len(att), "arrived": bool(arr.get(uid)), "note": f"{_name(h, others[0]).split()[0]} is here" if others else ""}


def _live_push(hid, h):
    from firebase_admin import messaging
    from google.cloud.firestore_v1 import DELETE_FIELD
    att = h.get("attendees") or []
    if not att or not _parse(h.get("start")):
        return
    everyone_here = all((h.get("arrivals") or {}).get(u) for u in att)
    for snap in _db.get_all([_db.collection("private").document(u) for u in att]):
        live = ((snap.to_dict() or {}).get("live") or {}).get(hid) if snap.exists else None
        if not live or not live.get("token") or not live.get("fcm"):
            continue
        now = int(time.time())
        aps = {"timestamp": now, "event": "end" if everyone_here else "update", "content-state": _live_state(h, snap.id)}
        if everyone_here:
            aps["dismissal-date"] = now + 5 * 60  # stays on the lock screen a few minutes, then goes
        try:
            messaging.send(messaging.Message(token=live["fcm"], apns=messaging.APNSConfig(
                live_activity_token=live["token"], headers={"apns-priority": "10"},
                payload=messaging.APNSPayload(aps=messaging.Aps(custom_data=aps)))))
        except Exception as e:
            print(f"[push] live activity: {e}")
            everyone_here = True  # that one's gone: forget it below
        if everyone_here:
            _db.collection("private").document(snap.id).update({f"live.{hid}": DELETE_FIELD})


# ---------- leave-now alerts ----------
def _alerts_tick():
    now = _now()
    for hid, h in list(_hangouts.items()):
        start = _parse(h.get("start"))
        if not start or start < now - timedelta(hours=1) or start > now + timedelta(hours=12):
            continue
        pushed = h.get("pushed") or {}
        for uid in h.get("attendees") or []:
            at = _parse((h.get("alerts") or {}).get(uid))
            if not at or not (now - ALERT_GRACE <= at <= now) or pushed.get(f"alert_{uid}") or (h.get("arrivals") or {}).get(uid):
                continue
            # mark first, so a slow send or a restart can't send it twice
            _db.collection("hangouts").document(hid).update({f"pushed.alert_{uid}": True})
            h.setdefault("pushed", {})[f"alert_{uid}"] = True
            mins = (h.get("travel") or {}).get(uid)
            where = h.get("venueName") or "the hangout"
            # in Ticki's voice (the app's mascot, a little alarm clock)
            body = f"Ticki here: head out now and you'll make {where} by {_local_time(h, h.get('start'))}" + (f" ({round(mins)} min trip)" if mins else "")
            send([uid], f"⏰ Time to go! {h.get('title') or 'Your hangout'}", body, {"hangout": hid, "kind": "alert"})


def _alerts_loop():
    while True:
        _safe(_alerts_tick)
        time.sleep(30)


# ---------- invites and yeses ----------
def _on_hangouts(docs, changes, read_time):
    first = not _on_hangouts.ready
    for ch in changes:
        hid, h = ch.document.id, ch.document.to_dict() or {}
        if ch.type.name == "REMOVED":
            _hangouts.pop(hid, None)
            continue
        old = _hangouts.get(hid)
        _hangouts[hid] = h
        if first:
            continue  # everything that already existed when the server started
        when = _local_time(h, h.get("start"))
        start = _parse(h.get("start"))
        when = f"{start.astimezone(ZoneInfo(h.get('tz') or 'America/New_York')).strftime('%a')} {when}" if start else when
        title = h.get("title") or "a hangout"
        old_invited = set((old or {}).get("invited") or [])
        new_invited = [u for u in h.get("invited") or [] if u not in old_invited and u not in (h.get("attendees") or [])]
        if new_invited:
            who = h.get("createdByName") or "A friend"
            _safe(send, new_invited, f"{who} invited you", f"{title} · {when}", {"hangout": hid, "kind": "invite"})
        if old and any(old.get(k) != h.get(k) for k in ("arrivals", "alerts", "attendees", "start")):
            _safe(_live_push, hid, h)
        if old:
            joined = [u for u in h.get("attendees") or [] if u not in (old.get("attendees") or [])]
            planner = h.get("createdBy")
            for u in joined:
                if planner and u != planner:
                    _safe(send, [planner], f"{_name(h, u)} is in", f"{title} · {when}", {"hangout": hid, "kind": "rsvp"})
    _on_hangouts.ready = True


_on_hangouts.ready = False


# ---------- chat messages ----------
_chats = {}  # chats/{id} cache: members, names, title, group


def _on_messages(docs, changes, read_time):
    first = not _on_messages.ready
    _on_messages.ready = True
    if first:
        return  # messages that were already there
    for ch in changes:
        if ch.type.name != "ADDED":
            continue
        m = ch.document.to_dict() or {}
        sent_at = _parse(m.get("at"))
        if not sent_at or _now() - sent_at > FRESH or m.get("kind") == "system":
            continue
        parent = ch.document.reference.parent.parent  # hangouts/{id} or chats/{id}
        if parent is None:
            continue
        sender, name, text = m.get("from"), m.get("name") or "A friend", str(m.get("text") or "")
        if parent.parent.id == "hangouts":
            h = _hangouts.get(parent.id) or (parent.get().to_dict() or {})
            to = [u for u in h.get("attendees") or [] if u != sender]
            body = f"{name} {text}" if m.get("kind") in ("arrived", "late", "left", "added") else f"{name}: {text}"
            _safe(send, to, h.get("title") or "Hangout chat", body, {"hangout": parent.id, "kind": "chat"})
        elif parent.parent.id == "chats":
            c = _chats.get(parent.id)
            if c is None:
                c = _chats[parent.id] = parent.get().to_dict() or {}
            to = [u for u in c.get("members") or [] if u != sender]
            if c.get("group"):
                _safe(send, to, c.get("title") or "Group chat", f"{name}: {text}", {"chat": parent.id, "kind": "dm"})
            else:
                _safe(send, to, name, text, {"chat": parent.id, "kind": "dm"})


_on_messages.ready = False


def _on_chats(docs, changes, read_time):  # keep members and titles current (people get added to groups)
    for ch in changes:
        if ch.type.name == "REMOVED":
            _chats.pop(ch.document.id, None)
        else:
            _chats[ch.document.id] = ch.document.to_dict() or {}


# ---------- start ----------
def start_background():
    global _db, _started
    if not ENABLED or _started:
        if not ENABLED:
            print("[push] off (set PUSH_ENABLED=1 on the live server to send notifications)")
        return
    try:
        from calendar_feed import firestore_client
        _db = firestore_client()
    except Exception as e:
        print(f"[push] off: no Firebase service account ({e})")
        return
    _started = True
    _db.collection("hangouts").on_snapshot(_on_hangouts)
    _db.collection("chats").on_snapshot(_on_chats)
    _db.collection_group("messages").on_snapshot(_on_messages)
    threading.Thread(target=_alerts_loop, daemon=True).start()
    print("[push] on: leave-now alerts, invites and chat messages")
