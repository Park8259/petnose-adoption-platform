const fs = require("node:fs");
const path = require("node:path");
const { after, before, beforeEach, describe, it } = require("node:test");

const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");
const {
  doc,
  getDoc,
  setDoc,
  updateDoc,
} = require("firebase/firestore");

const PROJECT_ID = "petnose-rules-test";
const ROOM_ID = "post_1_user_1";
const MESSAGE_ID = "message_1";
const TOKEN_HASH = "token_hash";

const rules = fs.readFileSync(
  path.resolve(__dirname, "../../docs/firebase/firestore.rules"),
  "utf8"
);

let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules },
  });
});

beforeEach(async () => {
  await testEnv.clearFirestore();
});

after(async () => {
  await testEnv.cleanup();
});

function authedDb(uid) {
  return testEnv.authenticatedContext(uid).firestore();
}

function unauthenticatedDb() {
  return testEnv.unauthenticatedContext().firestore();
}

async function seedChatData(participantUids = ["user_1", "user_2"]) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, "chat_rooms", ROOM_ID), {
      room_id: ROOM_ID,
      post_id: 1,
      author_uid: "user_2",
      inquirer_uid: "user_1",
      participant_uids: participantUids,
      room_status: "ACTIVE",
      message_enabled: true,
      status: "ACTIVE",
    });
    await setDoc(doc(db, "chat_rooms", ROOM_ID, "messages", MESSAGE_ID), {
      message_id: MESSAGE_ID,
      room_id: ROOM_ID,
      sender_uid: "user_1",
      type: "TEXT",
      text: "hello",
    });
    await setDoc(doc(db, "user_devices", "user_1"), {
      owner_uid: "user_1",
    });
    await setDoc(doc(db, "user_devices", "user_1", "tokens", TOKEN_HASH), {
      platform: "WEB",
      fcm_token: "dummy-token",
    });
  });
}

describe("PetNose Firestore chat rules", () => {
  it("allows a participant to read a chat room", async () => {
    await seedChatData();

    await assertSucceeds(getDoc(doc(authedDb("user_1"), "chat_rooms", ROOM_ID)));
  });

  it("denies a non-participant reading a chat room", async () => {
    await seedChatData();

    await assertFails(getDoc(doc(authedDb("user_3"), "chat_rooms", ROOM_ID)));
  });

  it("denies an unauthenticated user reading a chat room", async () => {
    await seedChatData();

    await assertFails(getDoc(doc(unauthenticatedDb(), "chat_rooms", ROOM_ID)));
  });

  it("allows a participant to read a message under a room", async () => {
    await seedChatData();

    await assertSucceeds(getDoc(doc(authedDb("user_1"), "chat_rooms", ROOM_ID, "messages", MESSAGE_ID)));
  });

  it("denies a non-participant reading a message under a room", async () => {
    await seedChatData();

    await assertFails(getDoc(doc(authedDb("user_3"), "chat_rooms", ROOM_ID, "messages", MESSAGE_ID)));
  });

  it("denies client chat room creation", async () => {
    const roomRef = doc(authedDb("user_1"), "chat_rooms", "post_2_user_1");

    await assertFails(setDoc(roomRef, {
      room_id: "post_2_user_1",
      participant_uids: ["user_1", "user_2"],
    }));
  });

  it("denies client chat room updates", async () => {
    await seedChatData();

    await assertFails(updateDoc(doc(authedDb("user_1"), "chat_rooms", ROOM_ID), {
      message_enabled: false,
    }));
  });

  it("denies client message creation", async () => {
    await seedChatData();

    await assertFails(setDoc(doc(authedDb("user_1"), "chat_rooms", ROOM_ID, "messages", "message_2"), {
      message_id: "message_2",
      room_id: ROOM_ID,
      sender_uid: "user_1",
      type: "TEXT",
      text: "client write should fail",
    }));
  });

  it("denies client message updates", async () => {
    await seedChatData();

    await assertFails(updateDoc(doc(authedDb("user_1"), "chat_rooms", ROOM_ID, "messages", MESSAGE_ID), {
      text: "edited by client",
    }));
  });

  it("denies client reads and writes for user device token documents", async () => {
    await seedChatData();
    const db = authedDb("user_1");

    await assertFails(getDoc(doc(db, "user_devices", "user_1")));
    await assertFails(getDoc(doc(db, "user_devices", "user_1", "tokens", TOKEN_HASH)));
    await assertFails(setDoc(doc(db, "user_devices", "user_1", "tokens", "new_token_hash"), {
      platform: "WEB",
      fcm_token: "client-write-denied",
    }));
    await assertFails(updateDoc(doc(db, "user_devices", "user_1", "tokens", TOKEN_HASH), {
      last_seen_at: "client-write-denied",
    }));
  });
});
