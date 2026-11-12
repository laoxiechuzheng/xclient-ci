import 'package:material_ui/material_ui.dart';

import '../../core/api/xboard_api.dart';
import '../common/format.dart';
import '../common/widgets.dart';
import 'support_pages.dart';

class XcTrafficLogPage extends StatelessWidget {
  const XcTrafficLogPage({super.key, required this.api});
  final XboardApi api;
  @override
  Widget build(BuildContext context) => XcPage(
    title: '流量明细',
    child: XcLoad<List<Map<String, dynamic>>>(
      load: api.trafficLog,
      builder: (context, records, refresh) => xcList([
        const Text('本月流量记录'),
        if (records.isEmpty) const Text('暂无流量记录'),
        for (final record in records)
          XcSection(
            title: XcFormat.date(record['record_at'], withTime: false),
            children: [
              XcValue('上传', XcFormat.bytes(record['u'])),
              XcValue('下载', XcFormat.bytes(record['d'])),
              XcValue('倍率', '${record['server_rate'] ?? 1} ×'),
            ],
          ),
      ]),
    ),
  );
}

class XcLoginLogPage extends StatefulWidget {
  const XcLoginLogPage({super.key, required this.api});
  final XboardApi api;
  @override
  State<XcLoginLogPage> createState() => _XcLoginLogPageState();
}

class _XcLoginLogPageState extends State<XcLoginLogPage> {
  int _page = 1;
  @override
  Widget build(BuildContext context) => XcPage(
    title: '登录记录',
    child: XcLoad<XbPage?>(
      key: ValueKey(_page),
      load: () => widget.api.loginLog(page: _page),
      emptyText: '此站点未开启登录记录',
      builder: (context, page, refresh) => xcList([
        if (page!.items.isEmpty) const Text('暂无登录记录'),
        for (final item in page.items)
          XcSection(
            children: [
              XcValue('登录时间', XcFormat.date(item['created_at'])),
              XcValue('IP 地址', item['ip']),
              XcValue(
                '设备',
                '${_map(item['device'])['type'] ?? '—'} / ${_map(item['device'])['os'] ?? '—'}',
              ),
              XcValue(
                '客户端',
                _map(item['device'])['browser'] ?? item['user_agent'],
              ),
              XcValue('结果', XcFormat.toBool(item['success']) ? '成功' : '失败'),
              XcValue(
                '归属地',
                [
                  for (final key in ['country', 'region', 'city'])
                    if (_map(item['location'])[key] != null)
                      '${_map(item['location'])[key]}',
                ].join(' '),
              ),
              XcValue('来源', item['origin']),
              if (XcFormat.toBool(item['is_current'])) const Text('当前设备'),
              XcValue('方式', item['type'] ?? item['login_method'] ?? '密码'),
            ],
          ),
        XcPagination(
          page: _page,
          hasNext: _page * 15 < page.total,
          onPage: (next) => setState(() => _page = next),
        ),
      ]),
    ),
  );
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Map<String, dynamic>> _rows(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList()
    : [];

class XcTrafficCyclePage extends StatefulWidget {
  const XcTrafficCyclePage({super.key, required this.api});
  final XboardApi api;
  @override
  State<XcTrafficCyclePage> createState() => _XcTrafficCyclePageState();
}

class _XcTrafficCyclePageState extends State<XcTrafficCyclePage> {
  int _page = 1;
  @override
  Widget build(BuildContext context) => XcPage(
    title: '流量周期',
    child: XcLoad<Map<String, dynamic>?>(
      key: ValueKey(_page),
      load: () => widget.api.trafficCycle(historyPage: _page, eventsSize: 50),
      emptyText: '此站点未开启流量周期',
      builder: (context, value, refresh) {
        final data = value!;
        final current = _map(data['current']);
        final advance = _map(data['advance']);
        final history = _rows(data['history']);
        return xcList([
          XcSection(
            title: '${_map(data['plan'])['name'] ?? '当前套餐'}',
            children: [
              XcValue(
                '重置方式',
                XcCycleText.resetMethods['${data['reset_method']}'] ??
                    data['reset_method'],
              ),
              XcValue('套餐到期', XcFormat.expiry(data['expired_at'])),
              if (advance.isNotEmpty)
                XcValue(
                  '提前换周期',
                  XcCycleText.advanceReasons['${advance['reason']}'] ??
                      (XcFormat.toBool(advance['eligible'])
                          ? '满足条件时自动换周期'
                          : '当前不可提前换周期'),
                ),
            ],
          ),
          if (current.isNotEmpty)
            XcCycleCard(title: '当前周期', cycle: current)
          else
            const Text('当前没有生效周期'),
          for (final cycle in _rows(data['upcoming']))
            XcCycleCard(title: '后续周期', cycle: cycle),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('历史周期'),
          ),
          if (history.isEmpty) const Text('暂无历史周期'),
          for (final cycle in history) XcCycleCard(title: '历史周期', cycle: cycle),
          XcPagination(
            page: _page,
            hasNext: _page * 10 < (XcFormat.toInt(data['history_total']) ?? 0),
            onPage: (next) => setState(() => _page = next),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('最近重置记录（最多 50 条）'),
          ),
          for (final event in _rows(data['events']))
            XcSection(
              title: XcCycleText.reason(event['reason']),
              children: [
                XcValue(
                  '时间',
                  XcFormat.date(event['at'] ?? event['created_at']),
                ),
                XcValue('清零流量', XcFormat.bytes(event['cleared'])),
                XcValue('原额度', XcFormat.bytes(event['quota_before'])),
                XcValue('新额度', XcFormat.bytes(event['quota_after'])),
                XcValue('结转流量', XcFormat.bytes(event['carried'])),
              ],
            ),
        ]);
      },
    ),
  );
}

class XcCycleCard extends StatelessWidget {
  const XcCycleCard({super.key, required this.title, required this.cycle});
  final String title;
  final Map<String, dynamic> cycle;
  @override
  Widget build(BuildContext context) => XcSection(
    title: title,
    children: [
      XcValue(
        '开始',
        XcFormat.date(
          cycle['started_at'] ?? cycle['starts_at'] ?? cycle['start_at'],
        ),
      ),
      XcValue('结束', XcFormat.date(cycle['ends_at'] ?? cycle['end_at'])),
      XcValue('本期额度', XcFormat.bytes(cycle['quota'])),
      if (cycle['used'] != null) XcValue('已用流量', XcFormat.bytes(cycle['used'])),
      if (cycle['remaining'] != null)
        XcValue('剩余流量', XcFormat.bytes(cycle['remaining'])),
      if (XcFormat.toBool(cycle['is_final'])) const Text('最后一个周期，结束后套餐到期'),
      if (cycle['reason'] != null || cycle['start_reason'] != null)
        XcValue(
          '变更原因',
          XcCycleText.reason(cycle['reason'] ?? cycle['start_reason']),
        ),
    ],
  );
}

class XcSessionsPage extends StatelessWidget {
  const XcSessionsPage({super.key, required this.api});
  final XboardApi api;
  @override
  Widget build(BuildContext context) => XcPage(
    title: '登录会话',
    child: XcLoad<List<Map<String, dynamic>>>(
      load: api.activeSessions,
      builder: (context, sessions, refresh) => xcList([
        if (sessions.isEmpty) const Text('暂无会话记录'),
        for (final session in sessions)
          XcSection(
            children: [
              XcValue('设备', session['device_name'] ?? '会话 #${session['id']}'),
              XcValue('IP 地址', session['ip']),
              XcValue('创建时间', XcFormat.date(session['created_at'])),
              XcValue('最近活动', XcFormat.date(session['last_used_at'])),
              if (XcFormat.toBool(session['is_current']))
                const Text('当前会话')
              else
                XcTaskButton(
                  label: '移除此会话',
                  tonal: true,
                  action: () async {
                    if (!await xcConfirm(context, '移除会话', '该会话将需要重新登录，确认继续？')) {
                      return;
                    }
                    await api.removeActiveSession(
                      XcFormat.toInt(session['id'])!,
                    );
                    await refresh();
                  },
                ),
            ],
          ),
      ]),
    ),
  );
}
