import 'dart:convert';

class User {
  final String id;
  final String username;
  final String displayName;
  final String bio;
  final String role;
  final DateTime? createdAt;

  const User({
    required this.id,
    required this.username,
    required this.displayName,
    this.bio = '',
    this.role = 'user',
    this.createdAt,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        username: json['username'] as String? ?? '',
        displayName: json['displayName'] as String? ?? json['username'] ?? '',
        bio: json['bio'] as String? ?? '',
        role: json['role'] as String? ?? 'user',
        createdAt: json['createdAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int)
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'displayName': displayName,
        'bio': bio,
        'role': role,
      };

  bool get isMod => role == 'mod';

  User copyWith({String? displayName, String? bio, String? role}) => User(
        id: id,
        username: username,
        displayName: displayName ?? this.displayName,
        bio: bio ?? this.bio,
        role: role ?? this.role,
        createdAt: createdAt,
      );
}

class Report {
  final String reporterId;
  final String reporterUsername;
  final String reporterDisplay;
  final String targetId;
  final String targetUsername;
  final String targetDisplay;
  final String reason;
  final DateTime createdAt;

  const Report({
    required this.reporterId,
    required this.reporterUsername,
    required this.reporterDisplay,
    required this.targetId,
    required this.targetUsername,
    required this.targetDisplay,
    required this.reason,
    required this.createdAt,
  });

  factory Report.fromJson(Map<String, dynamic> json) => Report(
        reporterId: json['reporterId'] as String,
        reporterUsername: json['reporterUsername'] as String? ?? '',
        reporterDisplay: json['reporterDisplay'] as String? ?? '',
        targetId: json['targetId'] as String,
        targetUsername: json['targetUsername'] as String? ?? '',
        targetDisplay: json['targetDisplay'] as String? ?? '',
        reason: json['reason'] as String? ?? '',
        createdAt: json['createdAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int)
            : DateTime.now(),
      );
}

class Attachment {
  final String id;
  final String name;
  final String mime;
  final int size;
  final String url;
  final DateTime createdAt;

  const Attachment({
    required this.id,
    required this.name,
    required this.mime,
    required this.size,
    required this.url,
    required this.createdAt,
  });

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'file',
        mime: json['mime'] as String? ?? 'application/octet-stream',
        size: (json['size'] as num?)?.toInt() ?? 0,
        url: json['url'] as String? ?? '',
        createdAt: json['createdAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int)
            : DateTime.now(),
      );
}

enum MessageKind { text, file, game }

class Message {
  final String id;
  final String conversationId;
  final String senderId;
  final String? senderName;
  final String? senderUsername;
  final MessageKind kind;
  final String body;
  final Attachment? attachment;
  final DateTime createdAt;
  final DateTime? readAt;
  final bool edited;
  final String? replyTo;
  final bool forwarded;
  final String? forwardedFrom;
  final bool deleted;
  final bool pinned;
  final List<MessageReaction> reactions;

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    this.senderName,
    this.senderUsername,
    required this.kind,
    required this.body,
    this.attachment,
    required this.createdAt,
    this.readAt,
    this.edited = false,
    this.replyTo,
    this.forwarded = false,
    this.forwardedFrom,
    this.deleted = false,
    this.pinned = false,
    this.reactions = const [],
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    final reactions = <MessageReaction>[];
    final reactionsRaw = json['reactions'];
    if (reactionsRaw is List) {
      for (final r in reactionsRaw) {
        if (r is Map) {
          final userIds = (r['userIds'] as List? ?? const [])
              .whereType<String>()
              .toList();
          if (r['emoji'] is String && userIds.isNotEmpty) {
            reactions.add(
                MessageReaction(emoji: r['emoji'] as String, userIds: userIds));
          }
        }
      }
    }
    return Message(
      id: json['id'] as String,
      conversationId: json['conversationId'] as String,
      senderId: json['senderId'] as String,
      senderName: json['senderName'] as String?,
      senderUsername: json['senderUsername'] as String?,
      kind: json['kind'] == 'file'
          ? MessageKind.file
          : json['kind'] == 'game'
              ? MessageKind.game
              : MessageKind.text,
      body: json['body'] as String? ?? '',
      attachment: json['attachment'] != null
          ? Attachment.fromJson(json['attachment'] as Map<String, dynamic>)
          : null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
      readAt: json['readAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['readAt'] as int)
          : null,
      edited: json['edited'] == true,
      replyTo: json['replyTo'] as String?,
      forwarded: json['forwardedFrom'] != null,
      forwardedFrom: json['forwardedFrom'] as String?,
      deleted: json['deleted'] == true,
      pinned: json['pinned'] == true,
      reactions: reactions,
    );
  }

  Map<String, dynamic>? get gameData {
    if (kind != MessageKind.game) return null;
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Message copyWith({
    DateTime? readAt,
    String? body,
    bool? edited,
    bool? deleted,
    bool? pinned,
    List<MessageReaction>? reactions,
  }) => Message(
        id: id,
        conversationId: conversationId,
        senderId: senderId,
        senderName: senderName,
        senderUsername: senderUsername,
        kind: kind,
        body: body ?? this.body,
        attachment: attachment,
        createdAt: createdAt,
        readAt: readAt ?? this.readAt,
        edited: edited ?? this.edited,
        replyTo: replyTo,
        forwarded: forwarded,
        forwardedFrom: forwardedFrom,
        deleted: deleted ?? this.deleted,
        pinned: pinned ?? this.pinned,
        reactions: reactions ?? this.reactions,
      );
}

/// A reaction on a message: one emoji plus the users who sent it.
class MessageReaction {
  final String emoji;
  final List<String> userIds;

  const MessageReaction({required this.emoji, required this.userIds});

  bool reactedBy(String userId) => userIds.contains(userId);
}

/// A user's membership in a group conversation.
class GroupMember {
  final User user;
  final String role; // owner | admin | member
  final bool muted;
  final DateTime createdAt;

  const GroupMember({
    required this.user,
    required this.role,
    this.muted = false,
    required this.createdAt,
  });

  factory GroupMember.fromJson(Map<String, dynamic> json) => GroupMember(
        user: User.fromJson(json['user'] as Map<String, dynamic>),
        role: json['role'] as String? ?? 'member',
        muted: json['muted'] as bool? ?? false,
        createdAt: json['createdAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int)
            : DateTime.now(),
      );

  bool get isOwner => role == 'owner';
  bool get isAdmin => role == 'owner' || role == 'admin';
}

class Conversation {
  final String id;
  final String kind; // 'dm' | 'group'
  final User? peer; // the other user, DMs only
  final String? name; // group title
  final String description; // group description
  final List<GroupMember> members; // group members (includes self)
  final String myRole; // my role in the group
  final bool muted; // my per-group mute
  final Message? lastMessage;
  final int unread;
  final DateTime createdAt;

  const Conversation({
    required this.id,
    this.kind = 'dm',
    this.peer,
    this.name,
    this.description = '',
    this.members = const [],
    this.myRole = 'member',
    this.muted = false,
    this.lastMessage,
    this.unread = 0,
    required this.createdAt,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String? ?? 'dm';
    return Conversation(
      id: json['id'] as String,
      kind: kind,
      peer: json['peer'] != null
          ? User.fromJson(json['peer'] as Map<String, dynamic>)
          : null,
      name: json['name'] as String?,
      description: json['description'] as String? ?? '',
      members: (json['members'] as List? ?? const [])
          .map((m) => GroupMember.fromJson(m as Map<String, dynamic>))
          .toList(),
      myRole: json['myRole'] as String? ?? 'member',
      muted: json['muted'] as bool? ?? false,
      lastMessage: json['lastMessage'] != null
          ? Message.fromJson(json['lastMessage'] as Map<String, dynamic>)
          : null,
      unread: (json['unread'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
    );
  }

  bool get isGroup => kind == 'group';

  String get title => isGroup ? (name ?? 'Group') : (peer?.displayName ?? '');

  /// Display name for a member id inside this group.
  String? memberName(String userId) {
    for (final m in members) {
      if (m.user.id == userId) return m.user.displayName;
    }
    return null;
  }

  Conversation copyWith({
    Object? lastMessage = _sentinel,
    Object? unread = _sentinel,
    Object? muted = _sentinel,
    Object? name = _sentinel,
    Object? description = _sentinel,
    Object? myRole = _sentinel,
    Object? members = _sentinel,
  }) =>
      Conversation(
        id: id,
        kind: kind,
        peer: peer,
        name: identical(name, _sentinel) ? this.name : name as String?,
        description: identical(description, _sentinel)
            ? this.description
            : (description as String?) ?? '',
        members: identical(members, _sentinel)
            ? this.members
            : (members as List<GroupMember>?) ?? const [],
        myRole: identical(myRole, _sentinel) ? this.myRole : (myRole as String?) ?? 'member',
        muted: identical(muted, _sentinel) ? this.muted : (muted as bool?) ?? false,
        lastMessage:
            identical(lastMessage, _sentinel) ? this.lastMessage : lastMessage as Message?,
        unread: identical(unread, _sentinel) ? this.unread : (unread as int?) ?? 0,
        createdAt: createdAt,
      );

  static const _sentinel = Object();
}

enum CallPhase { idle, outgoing, incoming, connecting, connected }

class CallSession {
  final String callId;
  final User peer;
  bool video;
  final bool outgoing;
  CallPhase phase;

  CallSession({
    required this.callId,
    required this.peer,
    required this.video,
    required this.outgoing,
    this.phase = CallPhase.outgoing,
  });
}

class ActiveGame {
  final String id;
  final String type; // 'rps' | 'guess'
  final bool mine;
  final bool myMoved;
  final bool peerMoved;
  final String peerId;
  final int? mySecret;
  final int guesses;
  final String status;

  const ActiveGame({
    required this.id,
    required this.type,
    required this.mine,
    required this.myMoved,
    required this.peerMoved,
    required this.peerId,
    this.mySecret,
    this.guesses = 0,
    required this.status,
  });

  factory ActiveGame.fromJson(Map<String, dynamic> json) => ActiveGame(
        id: json['id'] as String,
        type: json['type'] as String? ?? 'rps',
        mine: json['mine'] as bool? ?? false,
        myMoved: json['myMoved'] as bool? ?? false,
        peerMoved: json['peerMoved'] as bool? ?? false,
        peerId: json['peerId'] as String? ?? '',
        mySecret: (json['mySecret'] as num?)?.toInt(),
        guesses: (json['guesses'] as num?)?.toInt() ?? 0,
        status: json['status'] as String? ?? 'active',
      );
}