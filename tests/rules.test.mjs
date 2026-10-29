// Tests for firestore.rules against the Firestore emulator, following what the app really does.
// Run:  cd tests && npm i @firebase/rules-unit-testing firebase && npx firebase emulators:exec --only firestore "node --test rules.test.mjs"
// (or start an emulator yourself and set FIRESTORE_EMULATOR_HOST=127.0.0.1:8080)
import { test, before, after } from "node:test";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { initializeTestEnvironment, assertSucceeds, assertFails } from "@firebase/rules-unit-testing";
import { doc, setDoc, getDoc, updateDoc, deleteDoc, addDoc, collection, writeBatch, arrayUnion, arrayRemove, deleteField,
         query, where, getDocs } from "firebase/firestore";

const [host, port] = (process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080").split(":");
let env;
const db = uid => env.authenticatedContext(uid).firestore();
const anon = () => env.unauthenticatedContext().firestore();
const seed = fn => env.withSecurityRulesDisabled(c => fn(c.firestore()));
const JPEG = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD";
const soon = new Date(Date.now() + 864e5).toISOString();

before(async () => {
  env = await initializeTestEnvironment({ projectId: "omw-rules-test",
    firestore: { rules: readFileSync(new URL("../firestore.rules", import.meta.url), "utf8"), host, port: Number(port) } });
});
after(() => env.cleanup());

// alice and bob are friends; eve is a stranger
async function friends() {
  await env.clearFirestore();
  await seed(async f => {
    for (const [u, n] of [["alice", "Alice"], ["bob", "Bob"], ["eve", "Eve"]]) await setDoc(doc(f, "users", u), { name: n });
    await setDoc(doc(f, "users/alice/friends/bob"), {}); await setDoc(doc(f, "users/bob/friends/alice"), {});
  });
}
async function plan(extra = {}) {
  await seed(f => setDoc(doc(f, "hangouts", "h1"), { title: "Hot pot", start: soon, createdBy: "alice", attendees: ["alice"],
    invited: ["alice", "bob"], names: { alice: "Alice", bob: "Bob" }, modes: {}, alerts: {}, travel: {}, rsvp: { alice: "going" }, ...extra }));
}

test("nobody signed out gets anything", async () => {
  await friends();
  await assertFails(getDoc(doc(anon(), "users", "alice")));
  await assertFails(setDoc(doc(anon(), "users", "x"), { name: "x" }));
});

test("profiles: yours, and your friends' (not strangers')", async () => {
  await friends();
  await assertSucceeds(setDoc(doc(db("alice"), "users", "alice"), { name: "Alice A", freeUntil: soon }, { merge: true }));
  await assertSucceeds(getDoc(doc(db("bob"), "users", "alice")));
  await assertFails(getDoc(doc(db("eve"), "users", "alice")));
  await assertFails(setDoc(doc(db("eve"), "users", "alice"), { name: "hacked" }, { merge: true }));
  await assertFails(setDoc(doc(db("alice"), "users", "alice"), { photo: "javascript:alert(1)" }, { merge: true }));
});

test("friend requests: only an accepted request makes friends", async () => {
  await friends();
  await assertFails(setDoc(doc(db("eve"), "users/alice/friends/eve"), {}));  // can't add yourself to someone's list
  await assertFails(setDoc(doc(db("eve"), "requests", "alice_bob"), { from: "alice", to: "bob" }));  // can't send as someone else
  await assertSucceeds(setDoc(doc(db("eve"), "requests", "eve_alice"), { from: "eve", to: "alice", fromName: "Eve" }));
  await assertFails(getDoc(doc(db("bob"), "requests", "eve_alice")));
  const a = db("alice"), b = writeBatch(a);
  b.set(doc(a, "users/alice/friends/eve"), {}); b.set(doc(a, "users/eve/friends/alice"), {});
  b.delete(doc(a, "requests", "eve_alice"));
  await assertSucceeds(b.commit());
  await assertSucceeds(deleteDoc(doc(db("eve"), "users/alice/friends/eve")));  // unfriending works from either side
});

test("friend IDs", async () => {
  await friends();
  await assertSucceeds(setDoc(doc(db("alice"), "codes", "ALICE_1"), { uid: "alice", name: "Alice" }));
  await assertSucceeds(getDoc(doc(db("eve"), "codes", "ALICE_1")));
  await assertFails(setDoc(doc(db("eve"), "codes", "ALICE_1"), { uid: "eve", name: "Eve" }));
  await assertFails(setDoc(doc(db("eve"), "codes", "BOB"), { uid: "bob" }));
});

test("plans: who sees them and who changes what", async () => {
  await friends(); await plan();
  await assertSucceeds(addDoc(collection(db("alice"), "hangouts"), { title: "Boba", start: soon, createdBy: "alice", attendees: ["alice"], invited: ["alice", "bob"] }));
  await assertFails(addDoc(collection(db("eve"), "hangouts"), { title: "x", start: soon, createdBy: "alice", attendees: ["alice"] }));
  await assertSucceeds(getDoc(doc(db("bob"), "hangouts", "h1")));
  await assertFails(getDoc(doc(db("eve"), "hangouts", "h1")));
  await assertSucceeds(getDocs(query(collection(db("bob"), "hangouts"), where("invited", "array-contains", "bob"))));
  // the planner edits while nobody else has said yes
  await assertSucceeds(updateDoc(doc(db("alice"), "hangouts", "h1"), { title: "Hot pot!", [`alerts.bob`]: deleteField() }));
  // bob says yes, with his own leave time
  await assertSucceeds(updateDoc(doc(db("bob"), "hangouts", "h1"), { attendees: arrayUnion("bob"), "rsvp.bob": "going",
    "modes.bob": "transit", "alerts.bob": soon, "travel.bob": 18 }));
  // ...but can't touch Alice's part, add someone else, or rename it
  await assertFails(updateDoc(doc(db("bob"), "hangouts", "h1"), { "alerts.alice": soon }));
  await assertFails(updateDoc(doc(db("bob"), "hangouts", "h1"), { attendees: arrayUnion("eve") }));
  await assertFails(updateDoc(doc(db("bob"), "hangouts", "h1"), { title: "mine now" }));
  await assertFails(updateDoc(doc(db("bob"), "hangouts", "h1"), { createdBy: "bob" }));
  // now it's locked for the planner too, and she can't delete it under Bob
  await assertFails(updateDoc(doc(db("alice"), "hangouts", "h1"), { title: "Changed" }));
  await assertFails(deleteDoc(doc(db("alice"), "hangouts", "h1")));
  // check-ins: your own arrival only
  await assertSucceeds(updateDoc(doc(db("bob"), "hangouts", "h1"), { "arrivals.bob": new Date().toISOString() }));
  await assertFails(updateDoc(doc(db("bob"), "hangouts", "h1"), { "arrivals.alice": new Date().toISOString() }));
  // anyone going can invite more friends
  await assertSucceeds(updateDoc(doc(db("bob"), "hangouts", "h1"), { invited: arrayUnion("eve"), "names.eve": "Eve", "modes.eve": "driving" }));
  await assertFails(updateDoc(doc(db("bob"), "hangouts", "h1"), { invited: arrayRemove("alice") }));
  // bob can't make it
  await assertSucceeds(updateDoc(doc(db("bob"), "hangouts", "h1"), { attendees: arrayRemove("bob"), "rsvp.bob": "declined" }));
});

test("plan chats and live locations: only the people going", async () => {
  await friends(); await plan({ attendees: ["alice", "bob"] });
  await assertSucceeds(addDoc(collection(db("bob"), "hangouts/h1/messages"), { from: "bob", name: "Bob", text: "omw", at: soon }));
  await assertFails(addDoc(collection(db("bob"), "hangouts/h1/messages"), { from: "alice", name: "Alice", text: "fake", at: soon }));
  await assertFails(addDoc(collection(db("bob"), "hangouts/h1/messages"), { from: "bob", text: "x".repeat(1001) }));
  await assertFails(getDocs(collection(db("eve"), "hangouts/h1/messages")));
  await assertSucceeds(setDoc(doc(db("bob"), "hangouts/h1/where/bob"), { lat: 1, lng: 2, at: soon }));
  await assertFails(setDoc(doc(db("bob"), "hangouts/h1/where/alice"), { lat: 1, lng: 2 }));
  await assertFails(getDocs(collection(db("eve"), "hangouts/h1/where")));
});

test("group photos and the feed", async () => {
  await friends(); await plan({ attendees: ["alice", "bob"] });
  await assertFails(setDoc(doc(db("alice"), "memories", "h1"), { by: "alice", members: ["alice", "eve"], photo: JPEG }));
  await assertFails(setDoc(doc(db("alice"), "memories", "h1"), { by: "alice", members: ["alice", "bob"], photo: "data:text/html;base64,PHNjcmlwdD4=" }));
  await assertSucceeds(setDoc(doc(db("alice"), "memories", "h1"), { by: "alice", members: ["alice", "bob"], photo: JPEG, at: soon }));
  await assertFails(getDoc(doc(db("eve"), "memories", "h1")));
  // shared to the feed: Alice's friends and Bob's
  await assertFails(setDoc(doc(db("bob"), "feed", "h1"), { by: "bob", members: ["alice", "bob"], viewers: ["bob"], photo: JPEG }));  // not his photo
  await assertSucceeds(setDoc(doc(db("alice"), "feed", "h1"), { by: "alice", members: ["alice", "bob"], viewers: ["alice", "bob"],
    photo: JPEG, likes: [], ratings: {}, at: soon }));
  await assertSucceeds(updateDoc(doc(db("bob"), "feed", "h1"), { viewers: arrayUnion("eve"), "ratings.bob": 9 }));
  await assertFails(updateDoc(doc(db("bob"), "feed", "h1"), { "ratings.alice": 2 }));
  await assertFails(updateDoc(doc(db("bob"), "feed", "h1"), { "ratings.bob": 100 }));
  await assertFails(updateDoc(doc(db("bob"), "feed", "h1"), { viewers: arrayRemove("alice") }));
  // eve sees it, can like it, and can't do anything else
  await assertSucceeds(getDoc(doc(db("eve"), "feed", "h1")));
  await assertSucceeds(getDocs(query(collection(db("eve"), "feed"), where("viewers", "array-contains", "eve"))));
  await assertSucceeds(updateDoc(doc(db("eve"), "feed", "h1"), { likes: arrayUnion("eve") }));
  await assertFails(updateDoc(doc(db("eve"), "feed", "h1"), { likes: arrayUnion("bob") }));
  await assertFails(updateDoc(doc(db("eve"), "feed", "h1"), { photo: JPEG + "AA" }));
  await assertFails(deleteDoc(doc(db("eve"), "feed", "h1")));
  // reporting it
  await assertSucceeds(setDoc(doc(db("eve"), "reports", "h1_eve"), { post: "h1", by: "eve", poster: "alice", at: soon }));
  await assertFails(getDoc(doc(db("eve"), "reports", "h1_eve")));
  await assertSucceeds(deleteDoc(doc(db("alice"), "feed", "h1")));
});

test("posts and comments: friends only", async () => {
  await friends();
  const post = { kind: "post", by: "alice", members: ["alice"], names: { alice: "Alice" }, photo: JPEG, caption: "sunset", at: soon,
                 viewers: ["alice", "bob"], likes: [], ratings: {} };
  await assertFails(setDoc(doc(db("alice"), "feed", "p1"), { ...post, members: ["alice", "bob"] }));  // only you in your own post
  await assertFails(setDoc(doc(db("alice"), "feed", "p1"), { ...post, caption: "x".repeat(501) }));
  await assertFails(setDoc(doc(db("eve"), "feed", "p1"), { ...post }));  // not as someone else
  await assertSucceeds(setDoc(doc(db("alice"), "feed", "p1"), post));
  await assertSucceeds(setDoc(doc(db("alice"), "feed", "p3"), { ...post, photos: [JPEG, JPEG, JPEG] }));  // several photos
  await assertFails(setDoc(doc(db("alice"), "feed", "p4"), { ...post, photos: [JPEG, JPEG, JPEG, JPEG, JPEG] }));
  await assertFails(setDoc(doc(db("alice"), "feed", "p5"), { ...post, photos: [JPEG, "data:text/html;base64,AAAA"] }));
  await assertSucceeds(getDoc(doc(db("bob"), "feed", "p1")));
  await assertFails(getDoc(doc(db("eve"), "feed", "p1")));
  await assertFails(updateDoc(doc(db("alice"), "feed", "p1"), { kind: "" }));
  await assertSucceeds(addDoc(collection(db("bob"), "feed/p1/comments"), { from: "bob", name: "Bob", text: "nice", at: soon }));
  await assertFails(addDoc(collection(db("bob"), "feed/p1/comments"), { from: "alice", name: "Alice", text: "fake", at: soon }));
  await assertFails(addDoc(collection(db("eve"), "feed/p1/comments"), { from: "eve", text: "hi", at: soon }));
  await assertFails(getDocs(collection(db("eve"), "feed/p1/comments")));
  const c = await addDoc(collection(db("bob"), "feed/p1/comments"), { from: "bob", name: "Bob", text: "second", at: soon });
  await assertSucceeds(deleteDoc(doc(db("alice"), "feed/p1/comments", c.id)));  // the poster can remove comments on their post
  await assertSucceeds(setDoc(doc(db("bob"), "reports", `p1_${c.id}_bob`), { post: "p1", comment: c.id, by: "bob", at: soon }));
  await assertSucceeds(deleteDoc(doc(db("alice"), "feed", "p1")));
});

test("private and public accounts", async () => {
  await friends();
  const post = { kind: "post", by: "alice", members: ["alice"], names: { alice: "Alice" }, photo: JPEG, caption: "hi", at: soon,
                 viewers: ["alice", "bob"], likes: [], ratings: {}, public: false };
  await assertSucceeds(setDoc(doc(db("alice"), "feed", "p2"), post));
  await assertFails(getDoc(doc(db("eve"), "feed", "p2")));  // private: friends only
  assert.equal((await getDocs(query(collection(db("eve"), "feed"), where("by", "==", "alice"), where("public", "==", true)))).size, 0);
  await assertFails(getDocs(query(collection(db("eve"), "feed"), where("by", "==", "alice"))));  // can't ask for the private ones
  await assertSucceeds(getDocs(query(collection(db("bob"), "feed"), where("by", "==", "alice"), where("viewers", "array-contains", "bob"))));
  await assertFails(updateDoc(doc(db("bob"), "feed", "p2"), { public: true }));  // only the poster
  await assertSucceeds(updateDoc(doc(db("alice"), "feed", "p2"), { public: true }));
  await assertSucceeds(getDoc(doc(db("eve"), "feed", "p2")));  // public: anyone signed in
  await assertSucceeds(getDocs(query(collection(db("eve"), "feed"), where("by", "==", "alice"), where("public", "==", true))));
  await assertSucceeds(updateDoc(doc(db("eve"), "feed", "p2"), { likes: arrayUnion("eve") }));
  await assertSucceeds(addDoc(collection(db("eve"), "feed/p2/comments"), { from: "eve", name: "Eve", text: "cool", at: soon }));
  await assertSucceeds(setDoc(doc(db("alice"), "publicProfiles", "alice"), { name: "Alice", code: "ALICE", public: true }));
  await assertSucceeds(getDoc(doc(db("eve"), "publicProfiles", "alice")));
  await assertFails(setDoc(doc(db("eve"), "publicProfiles", "alice"), { name: "x" }));
});

test("chats", async () => {
  await friends();
  await assertSucceeds(getDoc(doc(db("alice"), "chats", "dm_alice_bob")));  // doesn't exist yet: the app checks first
  await assertSucceeds(setDoc(doc(db("alice"), "chats", "dm_alice_bob"), { members: ["alice", "bob"], group: false, createdBy: "alice", read: {} }));
  await assertFails(setDoc(doc(db("eve"), "chats", "dm_alice_bob2"), { members: ["alice", "bob", "eve"], group: false, createdBy: "eve" }));
  await assertFails(getDoc(doc(db("eve"), "chats", "dm_alice_bob")));
  await assertSucceeds(addDoc(collection(db("bob"), "chats/dm_alice_bob/messages"), { from: "bob", name: "Bob", text: "hi" }));
  await assertFails(addDoc(collection(db("eve"), "chats/dm_alice_bob/messages"), { from: "eve", text: "hi" }));
  await assertFails(updateDoc(doc(db("bob"), "chats", "dm_alice_bob"), { members: arrayUnion("eve") }));  // DMs stay two people
  await assertSucceeds(updateDoc(doc(db("bob"), "chats", "dm_alice_bob"), { "read.bob": soon, last: { text: "hi" } }));
  await assertFails(updateDoc(doc(db("bob"), "chats", "dm_alice_bob"), { "read.alice": soon }));
  const g = await assertSucceeds(addDoc(collection(db("alice"), "chats"), { members: ["alice", "bob"], group: true, title: "Crew", createdBy: "alice" }));
  await assertSucceeds(updateDoc(doc(db("alice"), "chats", g.id), { members: arrayUnion("eve"), "names.eve": "Eve" }));
  await assertFails(updateDoc(doc(db("alice"), "chats", g.id), { members: arrayRemove("bob") }));  // only yourself
  await assertSucceeds(updateDoc(doc(db("bob"), "chats", g.id), { members: arrayRemove("bob") }));
});

test("private data and everything else", async () => {
  await friends();
  await assertSucceeds(setDoc(doc(db("alice"), "private", "alice"), { pushTokens: ["t"], live: { h1: { token: "x" } } }, { merge: true }));
  await assertFails(getDoc(doc(db("bob"), "private", "alice")));
  await assertSucceeds(setDoc(doc(db("alice"), "locations", "alice"), { lat: 1, lng: 2, at: soon }));
  await assertSucceeds(getDoc(doc(db("bob"), "locations", "alice")));
  await assertFails(getDoc(doc(db("eve"), "locations", "alice")));
  await assertFails(setDoc(doc(db("alice"), "anything", "x"), { a: 1 }));
});
