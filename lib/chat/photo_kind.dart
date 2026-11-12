// Plain or private photo for a conversation (docs/planning/photo-e2e-private-2026-11-12.md, "Which messages get which kind").
// No user toggle. A photo in a place where only the members can read the text is private (end-to-end encrypted); only where
// anyone who knows a public name can read the text is the plain, public link used. When in doubt: private.
//
//   Direct message                                        -> private
//   Room server                                           -> private (members only)
//   Channel: the well-known Public channel                -> plain
//   Channel: hashtag (key derived from its name)          -> plain: anyone who knows the name can read it
//   Channel: private (random secret from a link / QR)     -> private
//   Channel: system (the wardrive channel), unknown row   -> private (the safe default)
// Pure Dart.
import 'models.dart';

enum PhotoKind { plain, private }

/// The kind for a conversation. [channel] is the saved channel row of a `c:<id>` key (null when it cannot be found).
PhotoKind photoKindFor(String convKey, Channel? channel) {
  switch (ConvKey.kindOf(convKey)) {
    case ConvKind.dm:
    case ConvKind.room:
    case null:
      return PhotoKind.private;
    case ConvKind.channel:
      if (channel == null) return PhotoKind.private;
      switch (channel.kind) {
        case ChannelKind.public:
        case ChannelKind.hashtag:
          return PhotoKind.plain;
        case ChannelKind.private:
        case ChannelKind.system:
          return PhotoKind.private;
      }
  }
}
