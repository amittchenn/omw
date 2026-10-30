"""
Deleting an account (account.py) against the Firestore emulator: everything about you goes, and what you shared with
other people stays theirs, without you in it.
Run:  start the emulator (firebase emulators:start --only firestore, or the emulator jar), then
      FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 python -m pytest tests/test_account.py
"""
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
pytestmark = pytest.mark.skipif(not os.getenv("FIRESTORE_EMULATOR_HOST"), reason="needs the Firestore emulator")


@pytest.fixture()
def db(monkeypatch):
    from google.cloud import firestore
    import firebase_admin.auth
    monkeypatch.setattr(firebase_admin.auth, "delete_user", lambda uid: None)  # no sign-in server here
    client = firestore.Client(project="demo-omw")
    for name in ("users", "requests", "codes", "hangouts", "memories", "feed", "chats", "publicProfiles", "private", "locations"):
        for d in client.collection(name).stream():
            client.recursive_delete(d.reference)
    return client


def seed(db):
    for u, n in (("alice", "Alice"), ("bob", "Bob"), ("carol", "Carol")):
        db.document(f"users/{u}").set({"name": n, "code": n.upper()})
    db.document("users/alice/friends/bob").set({}); db.document("users/bob/friends/alice").set({})
    db.document("codes/ALICE").set({"uid": "alice"})
    db.document("publicProfiles/alice").set({"name": "Alice"})
    db.document("locations/alice").set({"lat": 1, "lng": 2})
    # a plan Alice made that Bob is going to, and one only she's going to
    db.document("hangouts/h1").set({"createdBy": "alice", "attendees": ["alice", "bob"], "invited": ["alice", "bob", "carol"],
                                    "names": {"alice": "Alice", "bob": "Bob"}, "rsvp": {"alice": "going", "bob": "going"}})
    db.document("hangouts/h1/messages/m1").set({"from": "alice", "text": "hi", "at": "2026-10-01T10:00:00Z"})
    db.document("hangouts/h1/messages/m2").set({"from": "bob", "text": "yo", "at": "2026-10-01T10:01:00Z"})
    db.document("hangouts/h2").set({"createdBy": "alice", "attendees": ["alice"], "invited": ["alice"]})
    # a group photo Alice posted with Bob in it, and a post of her own
    db.document("memories/h1").set({"by": "alice", "members": ["alice", "bob"], "names": {"alice": "Alice", "bob": "Bob"}})
    db.document("feed/h1").set({"by": "alice", "byName": "Alice", "members": ["alice", "bob"], "viewers": ["alice", "bob"],
                                "names": {"alice": "Alice", "bob": "Bob"}, "likes": ["alice", "bob"], "ratings": {"alice": 9, "bob": 7}})
    db.document("feed/h1/comments/c1").set({"from": "alice", "text": "fun"})
    db.document("feed/h1/comments/c2").set({"from": "bob", "text": "so fun"})
    db.document("feed/p1").set({"kind": "post", "by": "alice", "members": ["alice"], "viewers": ["alice", "bob"]})
    # Bob's post that Alice liked and commented on
    db.document("feed/p2").set({"kind": "post", "by": "bob", "members": ["bob"], "viewers": ["bob", "alice"], "likes": ["alice"]})
    db.document("feed/p2/comments/c3").set({"from": "alice", "text": "nice"})
    # a 1:1 chat with Bob, one only Alice wrote in, and a group chat
    db.document("chats/dm_alice_bob").set({"members": ["alice", "bob"], "group": False, "names": {"alice": "Alice", "bob": "Bob"},
                                           "last": {"from": "alice", "text": "see you"}})
    db.document("chats/dm_alice_bob/messages/1").set({"from": "bob", "text": "dinner?", "at": "2026-10-01T09:00:00Z"})
    db.document("chats/dm_alice_bob/messages/2").set({"from": "alice", "text": "see you", "at": "2026-10-01T09:05:00Z"})
    db.document("chats/dm_alice_carol").set({"members": ["alice", "carol"], "group": False, "names": {}})
    db.document("chats/dm_alice_carol/messages/1").set({"from": "alice", "text": "hey", "at": "2026-10-01T09:00:00Z"})
    db.document("chats/g1").set({"members": ["alice", "bob", "carol"], "group": True, "names": {"alice": "Alice"},
                                 "last": {"from": "bob", "text": "hi all"}})
    db.document("chats/g1/messages/1").set({"from": "bob", "text": "hi all", "at": "2026-10-01T09:00:00Z"})


def test_delete_account(db):
    from account import delete_account
    seed(db)
    delete_account(db, "alice")
    get = lambda path: db.document(path).get().to_dict()

    # about her: gone
    for path in ("users/alice", "codes/ALICE", "publicProfiles/alice", "locations/alice", "users/bob/friends/alice", "feed/p1", "hangouts/h2"):
        assert get(path) is None, path
    # her plan with Bob: Bob's now, without her, his message kept
    h1 = get("hangouts/h1")
    assert h1["createdBy"] == "bob" and h1["attendees"] == ["bob"] and "alice" not in h1["invited"] and "alice" not in h1["rsvp"]
    assert get("hangouts/h1/messages/m1") is None and get("hangouts/h1/messages/m2")["text"] == "yo"
    # the group photo: Bob's now, without her
    assert get("memories/h1")["by"] == "bob" and get("memories/h1")["members"] == ["bob"]
    f = get("feed/h1")
    assert f["by"] == "bob" and f["byName"] == "Bob" and f["members"] == ["bob"] and f["likes"] == ["bob"] and f["ratings"] == {"bob": 7}
    assert get("feed/h1/comments/c1") is None and get("feed/h1/comments/c2")["text"] == "so fun"
    # Bob's post: her like and comment gone
    assert get("feed/p2")["likes"] == [] and get("feed/p2/comments/c3") is None
    # the 1:1 with Bob stays for him: her message gone, she's "Deleted user", the preview is his message
    dm = get("chats/dm_alice_bob")
    assert dm["names"]["alice"] == "Deleted user" and dm["gone"] == ["alice"] and dm["last"]["text"] == "dinner?"
    assert get("chats/dm_alice_bob/messages/2") is None and get("chats/dm_alice_bob/messages/1")["text"] == "dinner?"
    # a 1:1 with nothing of Carol's in it: gone
    assert get("chats/dm_alice_carol") is None
    # the group: she left
    g = get("chats/g1")
    assert g["members"] == ["bob", "carol"] and "alice" not in g["names"] and g["last"]["text"] == "hi all"
