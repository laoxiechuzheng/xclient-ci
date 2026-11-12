import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/xboard_api.dart';
import '../common/components.dart';
import '../common/errors.dart';
import '../common/format.dart';
import '../common/gradient.dart';
import '../common/commerce.dart';
import '../common/tokens.dart';
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

  List<Widget> _services(BuildContext context) => [
    XcSection(
      title: '订单与服务',
      children: [
        XcMenuRow(
          title: '我的订单',
          subtitle: '查看支付状态，继续未完成的支付',
          glyph: AppGlyphs.requests,
          onTap: () => xcPush(context, XcOrdersPage(api: api)),
        ),
        XcMenuRow(
          title: '我的工单',
          subtitle: '遇到问题时联系客服',
          glyph: AppGlyphs.compose,
          onTap: () => xcPush(context, XcTicketsPage(api: api)),
        ),
        XcMenuRow(
          title: '站点公告',
          subtitle: '维护通知与线路更新',
          glyph: AppGlyphs.info,
          onTap: () => xcPush(context, XcNoticesPage(api: api)),
        ),
        XcMenuRow(
          title: '使用帮助',
          subtitle: '常见问题与使用教程',
          glyph: AppGlyphs.puzzle,
          onTap: () => xcPush(context, XcKnowledgePage(api: api)),
        ),
      ],
    ),
    XcSection(
      title: '权益与流量',
      children: [
        XcMenuRow(
          title: '邀请与佣金',
          subtitle: '邀请好友注册，获得佣金',
          glyph: AppGlyphs.link,
          tone: XcTone.success,
          onTap: () =>
              xcPush(context, XcInvitePage(api: api, panelWebUrl: panelWebUrl)),
        ),
        XcMenuRow(
          title: '礼品卡',
          subtitle: '兑换礼品卡，领取余额或套餐',
          glyph: AppGlyphs.star,
          tone: XcTone.success,
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
          subtitle: '每天的上传和下载用量',
          glyph: AppGlyphs.dataUsage,
          onTap: () => xcPush(context, XcTrafficLogPage(api: api)),
        ),
        XcMenuRow(
          title: '流量周期',
          subtitle: '流量何时重置，以及重置记录',
          glyph: AppGlyphs.sync,
          onTap: () => xcPush(context, XcTrafficCyclePage(api: api)),
        ),
      ],
    ),
  ];

  List<Widget> _security(BuildContext context) => [
    XcSection(
      title: '账户与安全',
      children: [
        XcMenuRow(
          title: '登录记录',
          subtitle: '最近在哪里登录过',
          glyph: AppGlyphs.logs,
          tone: XcTone.neutral,
          onTap: () => xcPush(context, XcLoginLogPage(api: api)),
        ),
        XcMenuRow(
          title: '登录会话',
          subtitle: '移除不认识的登录',
          glyph: AppGlyphs.key,
          tone: XcTone.neutral,
          onTap: () => xcPush(context, XcSessionsPage(api: api)),
        ),
        XcMenuRow(
          title: '设备管理',
          subtitle: '查看和移除已登录的设备',
          glyph: AppGlyphs.devices,
          tone: XcTone.neutral,
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
          subtitle: '修改密码、到期与流量提醒',
          glyph: AppGlyphs.lock,
          tone: XcTone.neutral,
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
      XcSection(
        title: '客户端设置',
        glyph: AppGlyphs.settings,
        children: settingsTiles,
      ),
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      final actions = Row(
        spacing: XcSpace.sm,
        children: [
          Expanded(
            child: XcTaskButton(
              label: '同步账户信息',
              glyph: AppGlyphs.refresh,
              variant: XcButtonVariant.secondary,
              action: onRefreshUser,
            ),
          ),
          Expanded(
            child: XcTaskButton(
              label: '退出登录',
              variant: XcButtonVariant.danger,
              action: () async {
                if (await xcConfirm(context, '退出登录', '本机登录信息和节点配置将被清除，确认退出？')) {
                  await onLogout();
                }
              },
            ),
          ),
        ],
      );
      return xcList([
        _ProfileCard(user: user),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: XcSpace.md,
            children: [
              Expanded(child: Column(children: _services(context))),
              Expanded(
                child: Column(children: [..._security(context), actions]),
              ),
            ],
          )
        else ...[
          ..._services(context),
          ..._security(context),
          actions,
        ],
      ]);
    },
  );
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.user});
  final Map<String, dynamic> user;
  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final email = '${user['email'] ?? ''}';
    final initial = email.isEmpty ? '我' : email.characters.first.toUpperCase();
    return XcSection(
      children: [
        Row(
          spacing: XcSpace.md,
          children: [
            DecoratedBox(
              decoration: XcGradientDecoration(
                gradient: colors.accentGradient,
                shape: AppShape.circle,
                shadows: XcShadow.glow(colors.accent, strength: 0.4),
              ),
              child: SizedBox.square(
                dimension: 52,
                child: Center(
                  child: Text(
                    initial,
                    style: AppTextStyle.title2
                        .of(context, emphasized: true)
                        .copyWith(color: colors.onAccent),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  SelectableText(
                    email.isEmpty ? '—' : email,
                    style: XcType.headline(context),
                  ),
                  Text(
                    '注册于 ${XcFormat.date(user['created_at'], withTime: false)}',
                    style: XcType.caption(context),
                  ),
                  Text(
                    '最近登录 ${XcFormat.date(user['last_login_at'])}',
                    style: XcType.caption(context),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (user['discount'] != null)
          Align(
            alignment: Alignment.centerLeft,
            child: XcBadge(
              label: '专属折扣 ${user['discount']}%',
              tone: XcTone.success,
              glyph: AppGlyphs.sparkle,
            ),
          ),
        Divider(height: XcSpace.xs, color: colors.hairline),
        Row(
          children: [
            Expanded(
              child: XcMetric(
                label: '账户余额',
                value: context.xcMoney(user['balance']),
                glyph: AppGlyphs.dataUsage,
                caption: '购买套餐时优先抵扣',
              ),
            ),
            Expanded(
              child: XcMetric(
                label: '可用佣金',
                value: context.xcMoney(user['commission_balance']),
                glyph: AppGlyphs.link,
                caption: '可转入余额使用',
              ),
            ),
          ],
        ),
      ],
    );
  }
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
        const Padding(
          padding: EdgeInsets.only(bottom: XcSpace.md),
          child: XcCallout(
            glyph: AppGlyphs.devices,
            title: '登录名额有限',
            message: '移除不再使用的设备可释放登录名额；移除当前设备会退出登录。',
          ),
        ),
        if (devices.isEmpty)
          const XcStateView(
            glyph: AppGlyphs.devices,
            title: '暂无已注册设备',
            message: '重新注册后，这台设备就能继续同步节点。',
          ),
        for (final device in devices)
          Padding(
            padding: const EdgeInsets.only(bottom: XcSpace.sm),
            child: XcPanel(
              elevated: true,
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                spacing: XcSpace.sm,
                children: [
                  XcGlyphWell(
                    glyph: AppGlyphs.devices,
                    tone: XcFormat.toBool(device['current'])
                        ? XcTone.success
                        : XcTone.neutral,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: [
                        Wrap(
                          spacing: XcSpace.xs,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '${device['device_name'] ?? device['platform'] ?? '设备'}',
                              style: XcType.headline(context),
                            ),
                            if (XcFormat.toBool(device['current']))
                              const XcBadge(
                                label: '当前设备',
                                tone: XcTone.success,
                              ),
                          ],
                        ),
                        Text(
                          '${device['platform'] ?? '—'} / ${device['app_version'] ?? '—'}'
                          ' · 最近使用 ${XcFormat.date(device['last_seen_at'])}',
                          style: XcType.caption(context),
                        ),
                      ],
                    ),
                  ),
                  XcTaskButton(
                    label: '移除设备',
                    size: XcButtonSize.small,
                    variant: XcButtonVariant.danger,
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
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: XcSpace.xs),
          child: XcTaskButton(
            label: '重新注册当前设备',
            glyph: AppGlyphs.refresh,
            expand: true,
            action: () async {
              await onRegister();
              await refresh();
            },
          ),
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
      builder: (context, user, refresh) {
        final bound =
            user['telegram_id'] != null && '${user['telegram_id']}' != '0';
        return xcList([
          XcSection(
            title: '通知提醒',
            glyph: AppGlyphs.clock,
            children: [
              XcToggleTile(
                label: '到期提醒',
                subtitle: '套餐快到期时提醒你续费',
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
                subtitle: '流量快用完时提醒你',
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
            glyph: AppGlyphs.lock,
            children: [
              XcMenuRow(
                title: '修改密码',
                subtitle: '修改后其他登录会话将失效',
                glyph: AppGlyphs.password,
                tone: XcTone.neutral,
                onTap: () => xcPush(context, XcChangePasswordPage(api: api)),
              ),
              Text(
                '怀疑节点信息泄露时，可以重置节点凭据，客户端会自动重新同步。',
                style: XcType.caption(context),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: XcTaskButton(
                  label: '重置节点凭据',
                  glyph: AppGlyphs.reset,
                  size: XcButtonSize.small,
                  variant: XcButtonVariant.danger,
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
                    if (context.mounted) {
                      xcMessage(context, '节点凭据已重置，将按服务器策略检查节点');
                    }
                  },
                ),
              ),
            ],
          ),
          XcSection(
            title: 'Telegram',
            glyph: AppGlyphs.send,
            trailing: XcBadge(
              label: bound ? '已绑定' : '未绑定',
              tone: bound ? XcTone.success : XcTone.neutral,
            ),
            children: [
              XcMenuRow(
                title: '机器人与绑定管理',
                subtitle: '在站点网页管理绑定',
                glyph: AppGlyphs.openExternal,
                tone: XcTone.neutral,
                onTap: () => xcPush(
                  context,
                  XcTelegramPage(api: api, panelWebUrl: panelWebUrl),
                ),
              ),
            ],
          ),
        ]);
      },
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
  final _form = GlobalKey<XcFormState>();
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

  InputDecoration _field(String label, Glyph glyph) =>
      InputDecoration(labelText: label, prefixIcon: GlyphIcon(glyph, size: 20));

  @override
  Widget build(BuildContext context) => XcPage(
    title: '修改密码',
    child: XcForm(
      key: _form,
      child: xcList([
        XcSection(
          children: [
            XcFieldTheme(
              floating: true,
              child: Column(
                spacing: XcSpace.sm,
                children: [
                  TextFormField(
                    controller: _old,
                    obscureText: true,
                    autocorrect: false,
                    decoration: _field('当前密码', AppGlyphs.lock),
                    validator: validateLoginPassword,
                  ),
                  TextFormField(
                    controller: _new,
                    obscureText: true,
                    autocorrect: false,
                    decoration: _field('新密码', AppGlyphs.key),
                    validator: validateLoginPassword,
                  ),
                  TextFormField(
                    controller: _confirm,
                    obscureText: true,
                    autocorrect: false,
                    decoration: _field('确认新密码', AppGlyphs.key),
                    validator: (value) =>
                        value != _new.text ? '两次输入的密码不一致' : null,
                  ),
                ],
              ),
            ),
            Row(
              spacing: 6,
              children: [
                GlyphIcon(
                  AppGlyphs.info,
                  size: 15,
                  color: XcColors.of(context).muted,
                ),
                Expanded(
                  child: Text('修改后其他登录会话将失效。', style: XcType.caption(context)),
                ),
              ],
            ),
            XcTaskButton(
              label: '保存新密码',
              loadingLabel: '正在保存',
              expand: true,
              size: XcButtonSize.large,
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
            const Row(
              spacing: XcSpace.sm,
              children: [
                XcGlyphWell(glyph: AppGlyphs.send, size: 44),
                Expanded(child: _TelegramTitle()),
              ],
            ),
            XcValue('站点机器人', bot['username']),
            Text('为保护节点凭据，请前往站点网页完成绑定或解绑。', style: XcType.secondary(context)),
            XcTaskButton(
              label: '打开账户管理',
              glyph: AppGlyphs.openExternal,
              expand: true,
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

class _TelegramTitle extends StatelessWidget {
  const _TelegramTitle();
  @override
  Widget build(BuildContext context) =>
      Text('绑定 Telegram 机器人', style: XcType.headline(context));
}
