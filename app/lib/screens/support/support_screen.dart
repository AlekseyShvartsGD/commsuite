import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/localizations.dart';
import '../chat/chat_screen.dart';

/// Compose a support request. Sending it opens a group conversation with the
/// signed-in user and every moderator on the server.
class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  final _subject = TextEditingController();
  final _message = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    final controller = CommsScope.read(context);
    final message = _message.text.trim();
    if (message.isEmpty) {
      controller.showSnack(
        L.t(
          'Describe the problem first',
          ru: 'Сначала опишите проблему',
        ),
      );
      return;
    }
    setState(() => _sending = true);
    final conversation = await controller.requestSupport(
      subject: _subject.text.trim(),
      message: message,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (conversation == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversation)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('Support', ru: 'Поддержка')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.support_agent,
                    size: 32,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          L.t('Commsuite technical support',
                              ru: 'Техническая поддержка Commsuite'),
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          L.t(
                            'Tell us what went wrong. Every moderator is invited '
                            'to the conversation, and you can keep replying here.',
                            ru: 'Расскажите, что пошло не так. К разговору будут '
                                'приглашены все модераторы, и вы сможете отвечать '
                                'прямо здесь.',
                          ),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _subject,
            maxLength: 120,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: L.t('Subject (optional)', ru: 'Тема (необязательно)'),
              hintText: L.t('e.g. Calls keep dropping', ru: 'напр. Звонки обрываются'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _message,
            minLines: 6,
            maxLines: 14,
            maxLength: 8000,
            decoration: InputDecoration(
              labelText: L.t('Describe the problem', ru: 'Опишите проблему'),
              hintText: L.t(
                'What were you doing when it happened? What did you expect?',
                ru: 'Что вы делали, когда это произошло? Что ожидали увидеть?',
              ),
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_outlined),
            label: Text(
              _sending
                  ? L.t('Sending…', ru: 'Отправка…')
                  : L.t('Send to support', ru: 'Отправить в поддержку'),
            ),
          ),
        ],
      ),
    );
  }
}
