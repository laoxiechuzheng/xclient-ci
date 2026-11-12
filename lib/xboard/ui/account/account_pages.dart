import 'package:material_ui/material_ui.dart';

import '../../core/api/xboard_api.dart';
import '../common/errors.dart';
import '../common/format.dart';
import '../common/commerce.dart';
import '../common/widgets.dart';
import '../store/store_pages.dart';
import 'gift_card_pages.dart';
import 'invite_pages.dart';
import 'record_pages.dart';
import 'support_pages.dart';

class XcAccountPage extends StatelessWidget {
  const XcAccountPage({
    super.key,
    required this.api,
    required this.user,
    required this.panelWebUrl,
    required this.onLogout,
    required this.onSync,
    required this.onRefreshUser,
    required this.onRegisterDevice,
    this.settingsTiles = const [],
  });
  final XboardApi api;
  final Map<String, dynamic> user;
  final String panelWebUrl;
  final Future<void> Function() onLogout;
  final Future<void> Function() onSync;
  final Future<void> Function() onRefreshUser;
  final Future<void> Function() onRegisterDevice;
  final List<Widget> settingsTiles;
  @override
  Widget build(BuildContext context) => xcList([
    XcSection(
      title: '我的账户',
      children: [
        XcValue('邮箱', user['email']),
        XcValue('账户余额', context.xcMoney(user['balance'])),
        XcValue('可用佣金', context.xcMoney(user['commission_balance'])),
        XcValue('注册时间', XcFormat.date(user['created_at'])),
        XcValue('最近登录', XcFormat.date(user['last_login_at'])),
        if (user['discount'] != null) XcValue('专属折扣', '${user['discount']}%'),
      ],
    ),
    XcSection(
      children: [
        XcMenuRow(
          title: '我的订单',
          onTap: () => xcPush(context, XcOrdersPage(api: api)),
        ),
        XcMenuRow(
          title: '我的工单',
          onTap: () => xcPush(context, XcTicketsPage(api: api)),
        ),
        XcMenuRow(
          title: '站点公告',
          onTap: () => xcPush(context, XcNoticesPage(api: api)),
        ),
        XcMenuRow(
          title: '使用帮助',
          onTap: () => xcPush(context, XcKnowledgePage(api: api)),
        ),
        XcMenuRow(
          title: '邀请与佣金',
          onTap: () =>
              xcPush(context, XcInvitePage(api: api, panelWebUrl: panelWebUrl)),
        ),
        XcMenuRow(
          title: '礼品卡',
          onTap: () => xcPush(
            context,
            XcGiftCardsPage(
              api: api,
              onRedeemed: () async {
                final effects = XcCommerceScope.maybeOf(context)?.entitlements;
                if (effects != null) {
                  await effects.giftCardRedeemed();
                } else {
                  await onRefreshUser();
                  await onSync();
                }
              },
            ),
          ),
        ),
        XcMenuRow(
          title: '流量明细',
          onTap: () => xcPush(context, XcTrafficLogPage(api: api)),
        ),
        XcMenuRow(
          title: '流量周期',
          onTap: () => xcPush(context, XcTrafficCyclePage(api: api)),
        ),
        XcMenuRow(
          title: '登录记录',
          onTap: () => xcPush(context, XcLoginLogPage(api: api)),
        ),
        XcMenuRow(
          title: '登录会话',
          onTap: () => xcPush(context, XcSessionsPage(api: api)),
        ),
        XcMenuRow(
          title: '设备管理',
          onTap: () => xcPush(
            context,
            XcDevicesPage(
              api: api,
              onLogout: onLogout,
              onRegister: onRegisterDevice,
            ),
          ),
        ),
        XcMenuRow(
          title: '账户安全与提醒',
          onTap: () => xcPush(
            context,
            XcAccountSettingsPage(
              api: api,
              panelWebUrl: panelWebUrl,
              onSync: onSync,
              onRefreshUser: onRefreshUser,
            ),
          ),
        ),
      ],
    ),
    if (settingsTiles.isNotEmpty)
      XcSection(title: '客户端设置', children: settingsTiles),
    XcTaskButton(label: '同步账户信息', tonal: true, action: onRefreshUser),
    XcTaskButton(
      label: '退出登录',
      tonal: true,
      action: () async {
        if (await xcConfirm(context, '退出登录', '本机登录信息和节点配置将被清除，确认退出？')) {
          await onLogout();
        }
      },
    ),
  ]);
}

class XcDevicesPage extends StatelessWidget {
  const XcDevicesPage({
    super.key,
    required this.api,
    required this.onLogout,
    required this.onRegister,
  });
  final XboardApi api;
  final Future<void> Function() onLogout;
  final Future<void> Function() onRegister;
  @override
  Widget build(BuildContext context) => XcPage(
    title: '设备管理',
    child: XcLoad<List<Map<String, dynamic>>>(
      load: api.devices,
      builder: (context, devices, refresh) => xcList([
        const Text('移除不再使用的设备可释放登录名额；移除当前设备会退出登录。'),
        if (devices.isEmpty) const Text('暂无已注册设备'),
        for (final device in devices)
          XcSection(
            title: '${device['device_name'] ?? device['platform'] ?? '设备'}',
            children: [
              XcValue(
                '平台 / 版本',
                '${device['platform'] ?? '—'} / ${device['app_version'] ?? '—'}',
              ),
              XcValue('最近使用', XcFormat.date(device['last_seen_at'])),
              if (XcFormat.toBool(device['current'])) const Text('当前设备'),
              XcTaskButton(
                label: '移除设备',
                tonal: true,
                action: () async {
                  final current = XcFormat.toBool(device['current']);
                  if (!await xcConfirm(
                    context,
                    '移除设备',
                    current ? '确认移除当前设备并退出登录？' : '确认移除此设备？该设备将无法继续拉取节点。',
                  )) {
                    return;
                  }
                  await api.revokeDevice('${device['device_id']}');
                  if (current) {
                    await onLogout();
                  } else {
                    await refresh();
                  }
                },
              ),
            ],
          ),
        XcTaskButton(
          label: '重新注册当前设备',
          action: () async {
            await onRegister();
            await refresh();
          },
        ),
      ]),
    ),
  );
}

class XcAccountSettingsPage extends StatelessWidget {
  const XcAccountSettingsPage({
    super.key,
    required this.api,
    required this.panelWebUrl,
    required this.onSync,
    required this.onRefreshUser,
  });
  final XboardApi api;
  final String panelWebUrl;
  final Future<void> Function() onSync;
  final Future<void> Function() onRefreshUser;
  @override
  Widget build(BuildContext context) => XcPage(
    title: '账户安全与提醒',
    child: XcLoad<Map<String, dynamic>>(
      load: api.userInfo,
      builder: (context, user, refresh) => xcList([
        XcSection(
          title: '通知提醒',
          children: [
            XcToggleTile(
              label: '到期提醒',
              value: XcFormat.toBool(user['remind_expire']),
              onChanged: (value) async {
                try {
                  await api.updateRemind(expire: value);
                  await refresh();
                  await onRefreshUser();
                } catch (error) {
                  if (context.mounted) xcMessage(context, xcErrorText(error));
                }
              },
            ),
            XcToggleTile(
              label: '流量提醒',
              value: XcFormat.toBool(user['remind_traffic']),
              onChanged: (value) async {
                try {
                  await api.updateRemind(traffic: value);
                  await refresh();
                  await onRefreshUser();
                } catch (error) {
                  if (context.mounted) xcMessage(context, xcErrorText(error));
                }
              },
            ),
          ],
        ),
        XcSection(
          title: '安全',
          children: [
            XcMenuRow(
              title: '修改密码',
              onTap: () => xcPush(context, XcChangePasswordPage(api: api)),
            ),
            XcTaskButton(
              label: '重置节点凭据',
              tonal: true,
              action: () async {
                if (!await xcConfirm(
                  context,
                  '重置节点凭据',
                  '原节点凭据会失效，客户端将自动重新同步。确认继续？',
                )) {
                  return;
                }
                await api.resetSecurity();
                await onSync();
                if (context.mounted) xcMessage(context, '节点凭据已重置，将按服务器策略检查节点');
              },
            ),
          ],
        ),
        XcSection(
          title: 'Telegram',
          children: [
            XcValue(
              '绑定状态',
              user['telegram_id'] == null || '${user['telegram_id']}' == '0'
                  ? '未绑定'
                  : '已绑定',
            ),
            XcMenuRow(
              title: '机器人与绑定管理',
              subtitle: '在站点网页管理绑定',
              onTap: () => xcPush(
                context,
                XcTelegramPage(api: api, panelWebUrl: panelWebUrl),
              ),
            ),
          ],
        ),
      ]),
    ),
  );
}

class XcChangePasswordPage extends StatefulWidget {
  const XcChangePasswordPage({super.key, required this.api});
  final XboardApi api;
  @override
  State<XcChangePasswordPage> createState() => _XcChangePasswordPageState();
}

class _XcChangePasswordPageState extends State<XcChangePasswordPage> {
  final _form = GlobalKey<FormState>();
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => XcPage(
    title: '修改密码',
    child: Form(
      key: _form,
      child: xcList([
        XcSection(
          children: [
            TextFormField(
              controller: _old,
              obscureText: true,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '当前密码'),
              validator: validateLoginPassword,
            ),
            TextFormField(
              controller: _new,
              obscureText: true,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '新密码'),
              validator: validateLoginPassword,
            ),
            TextFormField(
              controller: _confirm,
              obscureText: true,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '确认新密码'),
              validator: (value) => value != _new.text ? '两次输入的密码不一致' : null,
            ),
            const Text('修改后其他登录会话将失效。'),
            XcTaskButton(
              label: '保存新密码',
              action: () async {
                if (!_form.currentState!.validate()) return;
                await widget.api.changePassword(_old.text, _new.text);
                if (context.mounted) {
                  xcMessage(context, '密码已修改');
                  Navigator.pop(context);
                }
              },
            ),
          ],
        ),
      ]),
    ),
  );
}

class XcTelegramPage extends StatelessWidget {
  const XcTelegramPage({
    super.key,
    required this.api,
    required this.panelWebUrl,
  });
  final XboardApi api;
  final String panelWebUrl;
  @override
  Widget build(BuildContext context) => XcPage(
    title: 'Telegram 绑定',
    child: XcLoad<Map<String, dynamic>>(
      load: api.telegramBotInfo,
      builder: (context, bot, refresh) => xcList([
        XcSection(
          children: [
            XcValue('站点机器人', bot['username']),
            const Text('为保护节点凭据，请前往站点网页完成绑定或解绑。'),
            XcTaskButton(
              label: '打开账户管理',
              action: () async {
                final uri = Uri.tryParse(
                  panelWebUrl,
                )?.replace(fragment: '/profile');
                if (uri == null || !await xcOpenExternal(uri)) {
                  if (context.mounted) xcMessage(context, '无法打开站点账户页面');
                }
              },
            ),
          ],
        ),
      ]),
    ),
  );
}
