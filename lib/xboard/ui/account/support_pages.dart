import 'package:fl_clash/ui/typography.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/xboard_api.dart';
import '../common/format.dart';
import '../common/rich_content.dart';
import '../common/widgets.dart';

class XcNoticesPage extends StatefulWidget {
  const XcNoticesPage({super.key, required this.api});
  final XboardApi api;
  @override
  State<XcNoticesPage> createState() => _XcNoticesPageState();
}

class _XcNoticesPageState extends State<XcNoticesPage> {
  int _page = 1;
  @override
  Widget build(BuildContext context) => XcPage(
    title: '站点公告',
    child: XcLoad<XbPage>(
      key: ValueKey(_page),
      load: () => widget.api.notices(page: _page),
      builder: (context, data, refresh) => xcList([
        if (data.items.isEmpty) const Text('暂无公告'),
        for (final notice in data.items)
          XcSection(
            title: '${notice['title'] ?? '公告'}',
            children: [
              Text(
                XcFormat.date(notice['created_at']),
                style: AppTextStyle.footnote.of(context),
              ),
              XcRichContent(
                content: '${notice['content'] ?? notice['body'] ?? ''}',
              ),
            ],
          ),
        XcPagination(
          page: _page,
          hasNext: _page * 5 < data.total,
          onPage: (page) => setState(() => _page = page),
        ),
      ]),
    ),
  );
}

class XcPagination extends StatelessWidget {
  const XcPagination({
    super.key,
    required this.page,
    required this.hasNext,
    required this.onPage,
  });
  final int page;
  final bool hasNext;
  final ValueChanged<int> onPage;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    spacing: 12,
    children: [
      TextButton(
        onPressed: page > 1 ? () => onPage(page - 1) : null,
        child: const Text('上一页'),
      ),
      Text('第 $page 页'),
      TextButton(
        onPressed: hasNext ? () => onPage(page + 1) : null,
        child: const Text('下一页'),
      ),
    ],
  );
}

class XcKnowledgePage extends StatefulWidget {
  const XcKnowledgePage({super.key, required this.api});
  final XboardApi api;
  @override
  State<XcKnowledgePage> createState() => _XcKnowledgePageState();
}

class _XcKnowledgePageState extends State<XcKnowledgePage> {
  final _search = TextEditingController();
  String _keyword = '';
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => XcPage(
    title: '使用帮助',
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              labelText: '搜索知识库',
              suffixIcon: TextButton(
                onPressed: () => setState(() => _keyword = _search.text.trim()),
                child: const Text('搜索'),
              ),
            ),
            onSubmitted: (value) => setState(() => _keyword = value.trim()),
          ),
        ),
        Expanded(
          child: XcLoad<Map<String, List<Map<String, dynamic>>>>(
            key: ValueKey(_keyword),
            load: () => widget.api.knowledge(keyword: _keyword),
            builder: (context, categories, refresh) => xcList([
              if (categories.isEmpty) const Text('没有找到相关文章'),
              for (final entry in categories.entries)
                XcSection(
                  title: entry.key,
                  children: [
                    for (final article in entry.value)
                      XcMenuRow(
                        title: '${article['title'] ?? '文章'}',
                        onTap: () => xcPush(
                          context,
                          XcArticlePage(
                            api: widget.api,
                            id: XcFormat.toInt(article['id'])!,
                          ),
                        ),
                      ),
                  ],
                ),
            ]),
          ),
        ),
      ],
    ),
  );
}

class XcArticlePage extends StatelessWidget {
  const XcArticlePage({super.key, required this.api, required this.id});
  final XboardApi api;
  final int id;
  @override
  Widget build(BuildContext context) => XcPage(
    title: '知识库文章',
    child: XcLoad<Map<String, dynamic>>(
      load: () => api.knowledgeArticle(id),
      builder: (context, article, refresh) => xcList([
        XcSection(
          title: '${article['title'] ?? '文章'}',
          children: [XcRichContent(content: '${article['body'] ?? ''}')],
        ),
      ]),
    ),
  );
}

class XcTicketsPage extends StatelessWidget {
  const XcTicketsPage({super.key, required this.api});
  final XboardApi api;
  @override
  Widget build(BuildContext context) => XcPage(
    title: '我的工单',
    child: XcLoad<List<Map<String, dynamic>>>(
      load: api.tickets,
      builder: (context, tickets, refresh) => xcList([
        FilledButton(
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => XcNewTicketPage(api: api),
              ),
            );
            await refresh();
          },
          child: const Text('提交工单'),
        ),
        if (tickets.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Text('暂无工单')),
        for (final ticket in tickets)
          XcSection(
            children: [
              XcMenuRow(
                title: '${ticket['subject'] ?? '工单'}',
                subtitle:
                    '${XcTickets.statusLabel(ticket)} · ${XcTickets.levelLabel(ticket['level'])}优先级 · ${XcFormat.date(ticket['created_at'])}',
                onTap: () => xcPush(
                  context,
                  XcTicketPage(api: api, id: XcFormat.toInt(ticket['id'])!),
                ),
              ),
            ],
          ),
      ]),
    ),
  );
}

class XcNewTicketPage extends StatefulWidget {
  const XcNewTicketPage({super.key, required this.api});
  final XboardApi api;
  @override
  State<XcNewTicketPage> createState() => _XcNewTicketPageState();
}

class _XcNewTicketPageState extends State<XcNewTicketPage> {
  final _form = GlobalKey<FormState>();
  final _subject = TextEditingController();
  final _message = TextEditingController();
  int _level = 0;
  @override
  void dispose() {
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => XcPage(
    title: '提交工单',
    child: Form(
      key: _form,
      child: xcList([
        XcSection(
          children: [
            TextFormField(
              controller: _subject,
              decoration: const InputDecoration(labelText: '工单主题'),
              maxLength: 255,
              validator: (value) =>
                  value == null || value.trim().isEmpty ? '请填写主题' : null,
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in XcTickets.levelLabels.entries)
                  ChoiceChip(
                    label: Text('${entry.value}优先级'),
                    selected: _level == entry.key,
                    onSelected: (_) => setState(() => _level = entry.key),
                  ),
              ],
            ),
            TextFormField(
              controller: _message,
              decoration: const InputDecoration(labelText: '问题描述'),
              minLines: 5,
              maxLines: null,
              maxLength: 10000,
              validator: (value) =>
                  value == null || value.trim().isEmpty ? '请描述您的问题' : null,
            ),
            XcTaskButton(
              label: '提交',
              action: () async {
                if (!_form.currentState!.validate()) return;
                await widget.api.createTicket(
                  subject: _subject.text.trim(),
                  level: _level,
                  message: _message.text.trim(),
                );
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
      ]),
    ),
  );
}

class XcTicketPage extends StatefulWidget {
  const XcTicketPage({super.key, required this.api, required this.id});
  final XboardApi api;
  final int id;
  @override
  State<XcTicketPage> createState() => _XcTicketPageState();
}

class _XcTicketPageState extends State<XcTicketPage> {
  final _reply = TextEditingController();
  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => XcPage(
    title: '工单详情',
    child: XcLoad<Map<String, dynamic>>(
      load: () => widget.api.ticket(widget.id),
      builder: (context, ticket, refresh) {
        final messages = ticket['message'];
        return xcList([
          XcSection(
            title: '${ticket['subject'] ?? '工单'}',
            children: [
              XcValue('状态', XcTickets.statusLabel(ticket)),
              XcValue('创建时间', XcFormat.date(ticket['created_at'])),
            ],
          ),
          if (messages is List)
            for (final message in messages.whereType<Map>())
              XcSection(
                title: XcFormat.toBool(message['is_me']) ? '我' : '客服',
                children: [
                  Text('${message['message'] ?? ''}'),
                  Text(
                    XcFormat.date(message['created_at']),
                    style: AppTextStyle.footnote.of(context),
                  ),
                ],
              ),
          if (!XcTickets.isClosed(ticket))
            XcSection(
              children: [
                TextField(
                  controller: _reply,
                  decoration: const InputDecoration(labelText: '回复'),
                  minLines: 3,
                  maxLines: null,
                  maxLength: 10000,
                ),
                XcTaskButton(
                  label: '发送回复',
                  action: () async {
                    if (_reply.text.trim().isEmpty) {
                      xcMessage(context, '请填写回复内容');
                      return;
                    }
                    await widget.api.replyTicket(widget.id, _reply.text.trim());
                    if (!mounted) return;
                    _reply.clear();
                    await refresh();
                  },
                ),
                XcTaskButton(
                  label: '关闭工单',
                  tonal: true,
                  action: () async {
                    if (!await xcConfirm(context, '关闭工单', '问题已解决，确认关闭此工单？')) {
                      return;
                    }
                    await widget.api.closeTicket(widget.id);
                    await refresh();
                  },
                ),
              ],
            ),
        ]);
      },
    ),
  );
}
