import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/xboard_api.dart';
import '../common/components.dart';
import '../common/format.dart';
import '../common/rich_content.dart';
import '../common/tokens.dart';
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
        if (data.items.isEmpty)
          const XcStateView(
            glyph: AppGlyphs.info,
            title: '暂无公告',
            message: '有新的维护通知或线路更新时，会第一时间显示在这里。',
          ),
        for (final notice in data.items)
          XcSection(
            title: '${notice['title'] ?? '公告'}',
            children: [
              Row(
                spacing: 6,
                children: [
                  GlyphIcon(
                    AppGlyphs.clock,
                    size: 14,
                    color: XcColors.of(context).muted,
                  ),
                  Text(
                    XcFormat.date(notice['created_at']),
                    style: XcType.caption(context),
                  ),
                ],
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
  Widget build(BuildContext context) {
    if (page <= 1 && !hasNext) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: XcSpace.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: XcSpace.sm,
        children: [
          XcButton(
            label: '上一页',
            glyph: AppGlyphs.chevronBack,
            size: XcButtonSize.small,
            variant: XcButtonVariant.secondary,
            onPressed: page > 1 ? () => onPage(page - 1) : null,
          ),
          XcBadge(label: '第 $page 页'),
          XcButton(
            label: '下一页',
            size: XcButtonSize.small,
            variant: XcButtonVariant.secondary,
            onPressed: hasNext ? () => onPage(page + 1) : null,
          ),
        ],
      ),
    );
  }
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
  Widget build(BuildContext context) {
    final gutter = XcSpace.gutterOf(MediaQuery.sizeOf(context).width);
    return XcPage(
      title: '使用帮助',
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              gutter,
              XcSpace.xs,
              gutter,
              XcSpace.sm,
            ),
            child: XcFieldTheme(
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: '搜索知识库',
                  prefixIcon: const GlyphIcon(AppGlyphs.search, size: 20),
                  suffixIcon: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: XcButton(
                      label: '搜索',
                      size: XcButtonSize.small,
                      variant: XcButtonVariant.ghost,
                      onPressed: () =>
                          setState(() => _keyword = _search.text.trim()),
                    ),
                  ),
                ),
                onSubmitted: (value) => setState(() => _keyword = value.trim()),
              ),
            ),
          ),
          Expanded(
            child: XcLoad<Map<String, List<Map<String, dynamic>>>>(
              key: ValueKey(_keyword),
              load: () => widget.api.knowledge(keyword: _keyword),
              builder: (context, categories, refresh) => xcList([
                if (categories.isEmpty)
                  const XcStateView(
                    glyph: AppGlyphs.search,
                    title: '没有找到相关文章',
                    message: '换个关键词试试，或提交工单咨询客服。',
                  ),
                for (final entry in categories.entries)
                  XcSection(
                    title: entry.key,
                    glyph: AppGlyphs.puzzle,
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

({XcTone tone, Glyph glyph}) _ticketStyle(Map<String, dynamic> ticket) {
  if (XcTickets.isClosed(ticket)) {
    return (tone: XcTone.neutral, glyph: AppGlyphs.checkCircle);
  }
  return XcFormat.toInt(ticket['reply_status']) == 1
      ? (tone: XcTone.success, glyph: AppGlyphs.send)
      : (tone: XcTone.warning, glyph: AppGlyphs.clock);
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
        Padding(
          padding: const EdgeInsets.only(bottom: XcSpace.md),
          child: XcButton(
            label: '提交工单',
            glyph: AppGlyphs.add,
            expand: true,
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => XcNewTicketPage(api: api),
                ),
              );
              await refresh();
            },
          ),
        ),
        if (tickets.isEmpty)
          const XcStateView(
            glyph: AppGlyphs.compose,
            title: '暂无工单',
            message: '遇到连接、支付或账户问题时，提交工单后客服会尽快回复。',
          ),
        for (final ticket in tickets)
          Padding(
            padding: const EdgeInsets.only(bottom: XcSpace.sm),
            child: XcPanel(
              elevated: true,
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              onTap: () => xcPush(
                context,
                XcTicketPage(api: api, id: XcFormat.toInt(ticket['id'])!),
              ),
              child: Row(
                spacing: XcSpace.sm,
                children: [
                  XcGlyphWell(
                    glyph: _ticketStyle(ticket).glyph,
                    tone: _ticketStyle(ticket).tone,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: [
                        Text(
                          '${ticket['subject'] ?? '工单'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: XcType.headline(context),
                        ),
                        Text(
                          '${XcTickets.levelLabel(ticket['level'])}优先级 · ${XcFormat.date(ticket['created_at'], withTime: false)}',
                          style: XcType.caption(context),
                        ),
                      ],
                    ),
                  ),
                  XcBadge(
                    label: XcTickets.statusLabel(ticket),
                    tone: _ticketStyle(ticket).tone,
                  ),
                  GlyphIcon(
                    AppGlyphs.chevronForward,
                    size: 18,
                    color: XcColors.of(context).muted,
                  ),
                ],
              ),
            ),
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
  final _form = GlobalKey<XcFormState>();
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
    child: XcForm(
      key: _form,
      child: xcList([
        const Padding(
          padding: EdgeInsets.only(bottom: XcSpace.md),
          child: XcCallout(
            glyph: AppGlyphs.compose,
            title: '描述得越具体，解决得越快',
            message: '请写明遇到的问题、发生时间，以及正在使用的线路或订单号。',
          ),
        ),
        XcSection(
          children: [
            XcFieldTheme(
              floating: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: XcSpace.sm,
                children: [
                  TextFormField(
                    controller: _subject,
                    decoration: const InputDecoration(labelText: '工单主题'),
                    maxLength: 255,
                    validator: (value) =>
                        value == null || value.trim().isEmpty ? '请填写主题' : null,
                  ),
                  Text('优先级', style: XcType.label(context)),
                  Row(
                    spacing: XcSpace.xs,
                    children: [
                      for (final entry in XcTickets.levelLabels.entries)
                        Expanded(
                          child: _LevelChoice(
                            label: '${entry.value}优先级',
                            selected: _level == entry.key,
                            onTap: () => setState(() => _level = entry.key),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: XcSpace.xxs),
                  TextFormField(
                    controller: _message,
                    decoration: const InputDecoration(
                      labelText: '问题描述',
                      alignLabelWithHint: true,
                    ),
                    minLines: 5,
                    maxLines: null,
                    maxLength: 10000,
                    validator: (value) => value == null || value.trim().isEmpty
                        ? '请描述您的问题'
                        : null,
                  ),
                ],
              ),
            ),
            XcTaskButton(
              label: '提交',
              loadingLabel: '正在提交',
              glyph: AppGlyphs.send,
              expand: true,
              size: XcButtonSize.large,
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

class _LevelChoice extends StatelessWidget {
  const _LevelChoice({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: AnimatedContainer(
        duration: XcMotion.of(context, XcMotion.standard),
        decoration: ShapeDecoration(
          color: selected ? colors.accentSoft : colors.block,
          shape: XcRadius.pill.copyWith(
            side: BorderSide(
              color: selected ? colors.accent : Colors.transparent,
              width: 1.5,
            ),
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: XcRadius.pill,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: XcType.secondary(
                  context,
                ).copyWith(color: selected ? colors.accent : colors.title),
              ),
            ),
          ),
        ),
      ),
    );
  }
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
        final style = _ticketStyle(ticket);
        return xcList([
          XcSection(
            children: [
              Row(
                spacing: XcSpace.sm,
                children: [
                  XcGlyphWell(glyph: style.glyph, tone: style.tone),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: [
                        Text(
                          '${ticket['subject'] ?? '工单'}',
                          style: XcType.headline(context),
                        ),
                        Text(
                          '创建于 ${XcFormat.date(ticket['created_at'])}',
                          style: XcType.caption(context),
                        ),
                      ],
                    ),
                  ),
                  XcBadge(
                    label: XcTickets.statusLabel(ticket),
                    tone: style.tone,
                  ),
                ],
              ),
            ],
          ),
          if (messages is List)
            for (final message in messages.whereType<Map>())
              _Bubble(
                mine: XcFormat.toBool(message['is_me']),
                text: '${message['message'] ?? ''}',
                time: XcFormat.date(message['created_at']),
              ),
          if (!XcTickets.isClosed(ticket))
            XcSection(
              title: '继续回复',
              glyph: AppGlyphs.compose,
              children: [
                XcFieldTheme(
                  child: TextField(
                    controller: _reply,
                    decoration: const InputDecoration(labelText: '回复'),
                    minLines: 3,
                    maxLines: null,
                    maxLength: 10000,
                  ),
                ),
                Row(
                  spacing: XcSpace.sm,
                  children: [
                    Expanded(
                      child: XcTaskButton(
                        label: '关闭工单',
                        variant: XcButtonVariant.secondary,
                        action: () async {
                          if (!await xcConfirm(
                            context,
                            '关闭工单',
                            '问题已解决，确认关闭此工单？',
                          )) {
                            return;
                          }
                          await widget.api.closeTicket(widget.id);
                          await refresh();
                        },
                      ),
                    ),
                    Expanded(
                      child: XcTaskButton(
                        label: '发送回复',
                        loadingLabel: '正在发送',
                        glyph: AppGlyphs.send,
                        action: () async {
                          if (_reply.text.trim().isEmpty) {
                            xcMessage(context, '请填写回复内容');
                            return;
                          }
                          await widget.api.replyTicket(
                            widget.id,
                            _reply.text.trim(),
                          );
                          if (!mounted) return;
                          _reply.clear();
                          await refresh();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: XcSpace.xs),
              child: Text(
                '工单已关闭。如果问题再次出现，可以提交新的工单。',
                textAlign: TextAlign.center,
                style: XcType.caption(context),
              ),
            ),
        ]);
      },
    ),
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.mine, required this.text, required this.time});
  final bool mine;
  final String text;
  final String time;
  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    const corner = Radius.circular(AppCorner.lg);
    return Padding(
      padding: const EdgeInsets.only(bottom: XcSpace.sm),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: FractionallySizedBox(
            widthFactor: 0.86,
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: mine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(
                  mine ? '我 · $time' : '客服 · $time',
                  style: XcType.caption(context),
                ),
                DecoratedBox(
                  decoration: ShapeDecoration(
                    color: mine ? colors.accentSoft : colors.card,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.only(
                        topLeft: mine ? corner : const Radius.circular(6),
                        topRight: mine ? const Radius.circular(6) : corner,
                        bottomLeft: corner,
                        bottomRight: corner,
                      ),
                    ),
                    shadows: mine ? null : XcShadow.card(colors),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: SelectableText(text, style: XcType.body(context)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
