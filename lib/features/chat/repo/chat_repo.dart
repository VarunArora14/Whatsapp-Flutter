import 'dart:developer';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:whatsapp_ui/common/enums/message_enums.dart';
import 'package:whatsapp_ui/common/providers/message_reply_provider.dart';
import 'package:whatsapp_ui/common/repo/common_firebase_storage_repo.dart';
import 'package:whatsapp_ui/common/utils/utils.dart';
import 'package:whatsapp_ui/models/chat_contact_model.dart';
import 'package:whatsapp_ui/models/message_model.dart';
import 'package:whatsapp_ui/models/user_model.dart';

final chatRepositoryProvider = Provider((ref) {
  return ChatRepository(firestore: FirebaseFirestore.instance, auth: FirebaseAuth.instance);
  // return their own instance of the class rather than taking them as constructor parameters/ class dependencies
});

class ChatRepository {
  // authorise the user and get the chat from firestore
  final FirebaseFirestore firestore;
  final FirebaseAuth auth;
  ChatRepository({
    required this.firestore,
    required this.auth,
  });

  /// return stream of chat contacts of current user
  Stream<List<ChatContactModel>> getChatContacts() {
    // since we want stream, we use .snapshots() instead of .docs()
    return firestore
        .collection('users')
        .doc(auth.currentUser!.uid) // show contact list messages of current user
        .collection('chats')
        .snapshots() // want stream so snapshots otherwise .docs(), asyncMap better than map() as it returns a stream
        .asyncMap((event) async {
      List<ChatContactModel> chatContactMessages = [];
      // go through each chat contact and get the name, profile pic, time sent, contact id and last message
      // loop through every query snapshot and get the document snapshot using which we will be able to convert it to chat contact
      for (var document in event.docs) {
        // event is of type QuerySnapshot which contains 0 or more document snapshots
        var chatContact = ChatContactModel.fromMap(document.data()); // convert map from doc to chat contact model
        chatContactMessages.add(chatContact); // insert all chatContacts into this list
      }
      return chatContactMessages; // return the list of chat contacts to the contact_list file
      // this returned list will be broadcasted to the stream builder in contact_list file
    });
  }

  // the _saveDataToContactSubcollection() was similar to getChatContacts(), similarly, getUserMessages() will be
  // similar to _saveMessageToMessageSubcollection for getting messages for each user

  /// return stream of current user messages from firestore based on recieverId of the contact
  Stream<List<MessageModel>> getChatStream(String recieverId) {
    return firestore
        .collection('users')
        .doc(auth.currentUser!.uid)
        .collection('chats') // go to chats of current user and use doc next as we dont want stream of contacts
        .doc(recieverId) // like above and then choose the reciever id
        .collection('messages') // check the messages of that reciever
        .orderBy('timeSent') // sort by time where 'timeSent' is property
        .snapshots() // and send their snapshots converting them to message model
        .map((event) {
      List<MessageModel> userMessages = [];
      for (var document in event.docs) {
        // debugPrint(event.docs.toString());
        userMessages.add(MessageModel.fromMap(document.data())); // document.data() is a map of the message
        // debugPrint(userMessages.toString());
      }
      return userMessages;
    });
  }

  /// private method accesible from sendTextMessage() to display new messages on top of screen for both sender and receiver
  void _saveDataToContactSubcollection(
      UserModel sender, UserModel reciever, String messageText, DateTime timeSent) async {
    try {
      // for new message, we need to to send 2 requests, first for reciever to get chats and set data in StreamBuilder like below
      // users ->  reciever user id -> chats -> sender id -> set data(for viewing last message on top of contact_screen)
      var recieverContact = ChatContactModel(
          name: sender.name,
          profilePic: sender.profilePic,
          timeSent: timeSent,
          contactId: sender.uid,
          lastMessage:
              messageText); // view last message on contact_screen to show latest messages on top of screen

      await firestore
          .collection('users')
          .doc(reciever.uid) // store this data in reciever id
          .collection('chats') // have collection named chats for each reciever
          .doc(sender.uid) // have a document for each user by their senderId
          .set(recieverContact.toMap()); // save to reciever's collection converting to map

      // then do same for sender user id
      // users -> sender user id -> chats ->reciever id -> set data(for viewing last message on top of contact_screen)
      // do reverse of above for sender
      var senderContact = ChatContactModel(
          name: reciever.name,
          profilePic: reciever.profilePic,
          timeSent: timeSent,
          contactId: reciever.uid,
          lastMessage: messageText); // send this contact model to collection

      await firestore
          .collection('users')
          .doc(sender.uid) // save to current user doc
          .collection('chats') // have chats collection for sender
          .doc(reciever.uid) // document for chat from sender to reciever
          .set(senderContact.toMap()); // send mapped data to collection

      // this receiverContact and senderContact  map will contain the last sent message and time sent of that msg
    } catch (e) {
      print('save message to contact error: ${e.toString()}');
    }
  }

  /// save messages sent by sender to message subcollection of the reciever's 'messages' collection through
  ///  firestore using messages model class
  void _saveMessageToMessageSubcollection(
      {required String messageText,
      required String recieverId,
      required String senderName,
      required String recieverName,
      required DateTime timeSent,
      required String messageId,
      required MessageReply? messageReply, // if current message is a reply to another message,null if not a reply
      // required MessageEnum replyMessageType,
      required MessageEnum messageType}) async {
    try {
      // for each message we need to save to message subcollection based on the message model we created
      final message = MessageModel(
        senderId: auth.currentUser!.uid, // current user and senderUser in below func will point to same senderid
        recieverId: recieverId,
        messageText: messageText,
        timeSent: timeSent,
        isSeen: false, // change value based  on logic
        messageType: messageType,
        messageId: messageId,
        replyMessageText: (messageReply == null) ? '' : messageReply.messageData, // if null then no text else text
        repliedUser: (messageReply == null)
            ? ''
            : ((messageReply.isMe) ? senderName : recieverName), // if null then no text else text
// null check so no exception if no messageReply is null
        replyMessageType: (messageReply == null)
            ? MessageEnum.text
            : messageReply.messageType, // type taken from constructor of function
      );

      // do the below 2 times as we need to show stuff for both users
      // users -> senderUserId -> messages -> receiverUserId -> messages collection -> messageId -> store message
      await firestore
          .collection('users') // common collection for all users
          .doc(auth.currentUser!.uid) // in the document of current user or senderId(same thing)
          .collection('chats') // access the chats collection
          .doc(recieverId) // and access the recieverId for accessing chats with recieverId
          .collection('messages') // this collection has the messages btw sender and reciever
          .doc(messageId) // store message in this random generated messageId
          .set(message.toMap()); // map the message to map and save to collection

      // users -> recieverUserId -> messages/chats -> senderUserId  -> messages collection -> messageId -> store message

      await firestore
          .collection('users')
          .doc(recieverId) // this time we store this data in reciever so they can see it on their screen
          .collection('chats') // collection name for messages
          .doc(auth.currentUser!.uid) // document for sender as being viewed by reciever
          .collection('messages') // collection for messages inside chats for each user reciever chats to
          .doc(messageId) // store message in this random generated messageId
          .set(message.toMap());
    } catch (e) {
      print('save message to subcollection error ${e.toString()}');
    }
  }

  /// send text message of current user to the other user while storing in firestore
  void sendTextMessage({
    required BuildContext context,
    required String text,
    required String recieverId,
    required UserModel senderUser,
    required MessageReply? messageReply, // take message reply if any so save message collection can work
    // required MessageEnum replyMessageType,
  }) async {
    // we want more of sender than just id and name, so we need to get more info from senderUser

    try {
      debugPrint('repo mathod called');
      var timeSent = DateTime.now(); // get the time when message is sent
      UserModel receiverUserData; // get the receiver user data using recieverid

      var userDataMap = await firestore.collection('users').doc(recieverId).get();
      // get map of reciever
      receiverUserData = UserModel.fromMap(userDataMap.data()!); // can be null

      var messageId = const Uuid().v1(); // generate random message id based on time
      _saveDataToContactSubcollection(senderUser, receiverUserData, text, timeSent);

      // after data is saved to contact subcollection, we need to store it to message subcollection

      _saveMessageToMessageSubcollection(
          messageText: text,
          recieverId: recieverId,
          senderName: senderUser.name,
          recieverName: receiverUserData.name,
          timeSent: timeSent,
          messageId: messageId,
          messageReply: messageReply,
          messageType: MessageEnum.text);
    } catch (e) {
      print(e.toString());
      showSnackBar(context: context, message: 'Send text message failed: ${e.toString()}');
    }
  }

  // the above function cannot be tested bcos we use buildcontext here and then display errors, If we used
  // Future<String> and if string was returned if success or not then we can test this function

  /// method to send file to firestore storage and then send it to other user having logic to store in both sender and reciever, update the last message and time sent in both sender and reciever
  void sendFileMessage({
    required BuildContext context,
    required File file, // the file we have to send to other user via storing to firestore
    required String recieverId,
    // need recieverId for save to contact subcollection and message subcollection. we can create recieverModel using this id
    required UserModel senderModel, // need for _saveDataToContactSubcollection and messageCollection
    required ProviderRef ref, // interact with commonStorageProvider to get uploaded file url
    required MessageEnum messageType, // the type of file it is based on enum values
    required MessageReply? messageReply,
    // required MessageEnum replyMessageType,
  }) async {
    try {
      var timeSent = DateTime.now(); // get the time when message is sent
      var messageId = const Uuid().v1(); // generate random message id based on time
      // we store messages of call types together in chat folder with each type and the type has sender folder, then reciever folder and then message id file
      // chat -> messageType -> senderId -> reciever id -> messageId(the file name randomly chosen) -> store message
      // Note - this folder is inside firebase storage and not the database
      String fileUrl = await ref
          .read(commonFireBaseStorageRepoProvider)
          .storeFileToFirebase('chat/${messageType.type}/${senderModel.uid}/$recieverId/$messageId', file);
      // generate recieverModel here form firestore using recieverId
      var recieverUserMap = await firestore.collection('users').doc(recieverId).get(); // get map of reciever
      var recieverModel = UserModel.fromMap(recieverUserMap.data()!); // can be null

      String contactMsg; // logic for showing contactDataScreen when a file is last msg
      switch (messageType) {
        case MessageEnum.image:
          contactMsg = '📷 Photo';
          break;
        case MessageEnum.video:
          contactMsg = '🎥 Video';
          break;
        case MessageEnum.audio:
          contactMsg = '🎧 Audio';
          break;
        case MessageEnum.gif:
          contactMsg = 'GIF';
          break;
        default:
          contactMsg = 'Default file'; // our mistake but we should not reach here
      }

      // update contact subcollection as it shows the last message on top
      _saveDataToContactSubcollection(senderModel, recieverModel, contactMsg, timeSent);

      // update message subcollection by adding the fileUrl
      _saveMessageToMessageSubcollection(
        messageText: fileUrl, // in the msg url has to be shown in the chat screen
        recieverId: recieverId,
        senderName: senderModel.name,
        recieverName: recieverModel.name,
        timeSent: timeSent, // the time when this file is sent
        messageId: messageId, // random messageId for storing in firestore in messageModel
        messageType: messageType,
        messageReply: messageReply, // taken in constructor of function
      ); // based on enum values, we store the string(see MessageModel)
    } catch (e) {
      showSnackBar(context: context, message: e.toString());
    }
  }

  /// send GIF url to firestore storage and update msg to contact, message subcollection
  void sendGifMessage({
    required BuildContext context,
    required String gifUrl,
    required String recieverId,
    required UserModel senderUser,
    // required MessageEnum replyMessageType, // since this message can be replied, we need to know the type
    required MessageReply? messageReply, // contains info of reply message if any
  }) async {
    try {
      var timeSent = DateTime.now(); // get the time when message is sent
      UserModel receiverUserData; // get the receiver user data using recieverid

      var userDataMap = await firestore.collection('users').doc(recieverId).get();
      // get map of reciever
      receiverUserData = UserModel.fromMap(userDataMap.data()!); // can be null

      var messageId = const Uuid().v1(); // generate random message id based on time
      _saveDataToContactSubcollection(senderUser, receiverUserData, 'GIF', timeSent);
      // show on contact screen 'GIF' as the last message

      // after data is saved to contact subcollection, we need to store it to message subcollection

      _saveMessageToMessageSubcollection(
        messageText: gifUrl, // add this url which we will later render as real gif in chat screen
        recieverId: recieverId,
        senderName: senderUser.name,
        recieverName: receiverUserData.name,
        timeSent: timeSent,
        messageId: messageId,
        messageType: MessageEnum.gif,
        messageReply: messageReply, // will decide the if reply to self or other
      ); // dont forget to add gif massageType here
    } catch (e) {
      showSnackBar(context: context, message: 'Send text message failed: ${e.toString()}');
    }
  }

  /// mark the message seen based on their recieverId and messageId
  void setMessageSeen(BuildContext context, String recieverId, String messageId) async {
    try {
      // use the message subcollection of both reciever and sender as we have to update messages of both so they stay in sync
      await firestore
          .collection('users') // common collection for all users
          .doc(auth.currentUser!.uid) // in the document of current user or senderId(same thing)
          .collection('chats') // access the chats collection
          .doc(recieverId) // and access the recieverId for accessing chats with recieverId
          .collection('messages') // this collection has the messages btw sender and reciever
          .doc(messageId) // store message in this random generated messageId
          .update({
        'isSeen': true // update isSeen field to true for current message
      });

      // users -> recieverUserId -> messages/chats -> senderUserId  -> messages collection -> messageId -> store message

      await firestore
          .collection('users')
          .doc(recieverId) // this time we store this data in reciever so they can see it on their screen
          .collection('chats') // collection name for messages
          .doc(auth.currentUser!.uid) // document for sender as being viewed by reciever
          .collection('messages') // collection for messages inside chats for each user reciever chats to
          .doc(messageId) // store message in this random generated messageId
          .update({
        'isSeen': true // update isSeen field to true for current message
      });
    } catch (e) {
      showSnackBar(context: context, message: e.toString());
    }
  }
}

// Since there can be multiple users of same sender, we need to get the recieverUserId to send the message
// Since message is 2 sided in terms that reciever also has the messages stored
// in its chat collection, we need to get the reciever user model as well

// For sendTextMessage() understand the following -
/*
save in 2 collections 1. show the last message on top of contact_screen using StreamBuilder

    users ->  reciever user id -> chats -> set data(for viewing last message on top of contact_screen)
    If we dont have chats collection then we will have problem managing messages for each user as top
    message will be different for each user

    2. save the message in message Collection
    collection would be stored as users -> senderUserId -> receiverUserId -> messages -> messageId -> store message
*/
