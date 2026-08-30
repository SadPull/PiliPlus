import 'dart:convert';
import 'dart:math' show max;

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

/// 第三方高画质解析（移植自「网盘下载助手」油猴脚本）
///
/// 原理：把完整 wbi 签名的 playurl 请求地址连同账号信息（ui，含完整 Cookie）
/// 提交给解析服务器，由服务器携带用户 Cookie 代为请求 B 站并返回可替换的
/// playurl 响应，从而获得会员限定的高画质（qn > 80）。
///
/// 注意：该功能会把 B 站完整 Cookie 上报给第三方服务器（明文 HTTP），
/// 存在 Cookie 暴露与账号风控风险；每档画质消耗一次解析，有每日免费上限。
abstract final class QualityResolver {
  // ---- 会话状态 ----
  static int? _registeredMid;
  static final Map<String, Map<String, dynamic>> _cache = {};
  static DateTime? _quotaTipUntil;
  static DateTime? _downUntil;

  /// 功能开关 + 已登录
  static bool get canUse =>
      Pref.enableQualityUnlock && Accounts.main is LoginAccount;

  static LoginAccount? get _loginAccount =>
      Accounts.main is LoginAccount ? Accounts.main as LoginAccount : null;

  /// 连接层失败后的熔断：10 分钟内不再尝试，避免拖慢播放
  static bool get _circuitOpen {
    final downUntil = _downUntil;
    return downUntil != null && DateTime.now().isBefore(downUntil);
  }

  static Options get _options => Options(
    contentType: Headers.jsonContentType,
    validateStatus: (status) => true,
    // 解析服务器处理较慢(实测 >20s)，覆盖全局 10s 超时
    sendTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 90),
    // 外部服务器，不注入 B 站 Cookie / 账号头
    extra: {'account': const NoAccount()},
  );

  /// 组装与油猴脚本一致的 ui 字段
  static Future<Map<String, dynamic>?> buildUi() async {
    final account = _loginAccount;
    if (account == null) return null;
    final cookies = account.cookieJar.toJson();
    // 与脚本一致：缺少关键 Cookie 时直接放弃
    if (!cookies.containsKey('SESSDATA') || !cookies.containsKey('bili_jct')) {
      return null;
    }
    UserInfoData? user = Pref.userInfoCache;
    user ??= await _refreshUserInfo();
    if (user == null) return null;
    final money = user.money;
    return {
      'ua': BrowserUa.pc,
      'mid': account.mid.toString(),
      'vip': (user.vipStatus ?? 0) == 0 ? 0 : 1,
      'level': user.levelInfo?.currentLevel ?? 0,
      // 脚本逻辑：硬币数解析失败或 <1 记为 0
      'money': money != null && money >= 1 ? money.toInt() : 0,
      'cookie': cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      'csrf': cookies['bili_jct'],
      'face': user.face,
      'name': user.uname,
    };
  }

  static Future<UserInfoData?> _refreshUserInfo() async {
    try {
      final res = await UserHttp.userInfo();
      if (res case Success(:final response)) {
        GStorage.userInfo.put('userInfoCache', response);
        return response;
      }
    } catch (_) {}
    return null;
  }

  /// 会话内对当前账号做一次 bzusta 注册/校验
  static Future<bool> _ensureRegistered(int mid) async {
    if (_registeredMid == mid) return true;
    try {
      final ui = await buildUi();
      if (ui == null) return false;
      final res = await Request().post(
        '${Pref.qualityResolverHome}/api/bzusta',
        data: {'ui': ui},
        options: _options,
      );
      if (res.data is Map && res.data['code'] == 0) {
        _registeredMid = mid;
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// 经解析服务器换取 [qn] 画质的 playurl 响应信封
  ///
  /// 返回原始信封 JSON（ugc 为 {code, data}，pgc 为 {code, result}），
  /// 失败返回 null（已按需 Toast 提示原因）。
  ///
  /// 通道选择（与脚本一致）：
  /// - 番剧(pgc)：优先 POST /api/bzview3（转发 web 播放器的 playview 请求体），
  ///   失败自动回退 bzview2 + playurl 签名地址；
  /// - 普通视频(ugc/pugv)：POST /api/bzview2（playurl 签名地址）。
  static Future<Map<String, dynamic>?> resolvePlayUrl({
    required VideoType videoType,
    int? avid,
    String? bvid,
    required int cid,
    dynamic epid,
    dynamic seasonId,
    required bool tryLook,
    String? language,
    bool voiceBalance = false,
    required int qn,
    bool silent = false,
  }) async {
    final account = _loginAccount;
    if (account == null) return null;
    final key = '${videoType.name}:${bvid ?? avid}:$cid:$qn';
    if (_cache[key] case final Map<String, dynamic> cached) return cached;
    if (_circuitOpen) return null;

    try {
      if (!await _ensureRegistered(account.mid)) {
        if (!silent) SmartDialog.showToast('连接解析服务器失败');
        return null;
      }
      final ui = await buildUi();
      if (ui == null) return null;

      Map<String, dynamic>? envelope;
      if (videoType == .pgc) {
        envelope = await _post('bzview3', {
          'iic': false,
          'ui': ui,
          'body': jsonEncode({
            'avid': bvid != null ? IdUtils.bv2av(bvid) : (avid ?? 0),
            'cid': cid,
            'qn': qn,
            'fnver': 0,
            'fnval': 4048,
            'session': '',
            'ep_id': epid ?? 0,
          }),
        });
      }
      envelope ??= await _post('bzview2', {
        'ui': ui,
        'url': await VideoHttp.buildSignedPlayUrl(
          videoType: videoType,
          avid: avid,
          bvid: bvid,
          cid: cid,
          qn: qn,
          epid: epid,
          seasonId: seasonId,
          tryLook: tryLook,
          language: language,
          voiceBalance: voiceBalance,
        ),
      });
      if (envelope == null) return null;

      switch (envelope['code']) {
        case 0:
          return _cache[key] = envelope;
        case 9:
          _toastQuota();
          return null;
        case 1:
          if (!silent) SmartDialog.showToast('连接解析服务器失败');
          return null;
        default:
          final message = envelope['message'];
          if (!silent && message is String && message.isNotEmpty) {
            SmartDialog.showToast(message);
          }
          return null;
      }
    } catch (_) {}
    return null;
  }

  /// 向解析服务器的 /api/[api] 发送 POST，返回信封 JSON；连接层失败触发熔断
  static Future<Map<String, dynamic>?> _post(
    String api,
    Map<String, dynamic> data,
  ) async {
    try {
      final res = await Request().post(
        '${Pref.qualityResolverHome}/api/$api',
        data: data,
        options: _options,
      );
      if (res.statusCode == -1) {
        // 连接层失败（超时/不可达），熔断一段时间
        _downUntil = DateTime.now().add(const Duration(minutes: 10));
        return null;
      }
      return res.data is Map<String, dynamic> ? res.data : null;
    } catch (_) {
      return null;
    }
  }

  /// code=9 提示的 15 分钟冷却（与脚本一致）
  static void _toastQuota() {
    final now = DateTime.now();
    if (_quotaTipUntil != null && now.isBefore(_quotaTipUntil!)) return;
    _quotaTipUntil = now.add(const Duration(minutes: 15));
    SmartDialog.showToast('今日免费使用次数已达上限\n给任意视频投币可重置');
  }

  /// 剥离 need_login/need_vip 标记（等价于脚本的字符串替换）
  static void _stripFlags(dynamic node) {
    if (node is Map) {
      node.removeWhere(
        (key, value) =>
            (key == 'need_login' || key == 'need_vip') && value == true,
      );
      for (final value in node.values) {
        _stripFlags(value);
      }
    } else if (node is List) {
      for (final item in node) {
        _stripFlags(item);
      }
    }
  }

  /// 从服务器响应信封中取出对应 videoType 的 playurl 数据
  static Map<String, dynamic>? _payloadOf(
    VideoType videoType,
    Map<String, dynamic> envelope,
  ) {
    try {
      switch (videoType) {
        case .ugc:
        case .pugv:
          return envelope['data'] is Map<String, dynamic>
              ? envelope['data']
              : null;
        case .pgc:
          final result = envelope['result'];
          if (result is Map && result['video_info'] is Map<String, dynamic>) {
            return result['video_info'];
          }
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// 把解析结果合并进 [base]（仅新增原响应中没有的画质），任何异常 fail-open
  static bool mergeInto(
    PlayUrlModel base,
    Map<String, dynamic> envelope,
    VideoType videoType,
  ) {
    try {
      final payload = _payloadOf(videoType, envelope);
      if (payload == null) return false;
      _stripFlags(payload);
      final unlocked = PlayUrlModel.fromJson(payload);
      final dash = base.dash;
      final newDash = unlocked.dash;
      if (dash == null || newDash?.video == null) return false;

      // 视频轨：同一画质可能有多种编码，按 qn+codecs 去重后按 qn 降序排列
      //（播放器默认取列表首个为最高画质）
      final mergedVideo = [...?dash.video, ...?newDash?.video];
      final seen = <String>{};
      mergedVideo.retainWhere((e) => seen.add('${e.id}|${e.codecs ?? ''}'));
      mergedVideo.sort((a, b) => b.quality.code.compareTo(a.quality.code));
      if (mergedVideo.length == (dash.video?.length ?? 0)) return false;
      dash.video = mergedVideo;

      // 音频轨（解析响应可能携带更高规格音轨）
      final knownAudio = <int>{
        ...?dash.audio?.map((e) => e.id).whereType<int>(),
      };
      final newAudio = newDash?.audio;
      if (newAudio != null) {
        for (final item in newAudio) {
          if (item.id != null && knownAudio.add(item.id!)) {
            (dash.audio ??= []).add(item);
          }
        }
      }

      // 画质列表（support_formats）与 accept_quality/accept_description 取更全的一份
      if ((unlocked.supportFormats?.length ?? 0) >
          (base.supportFormats?.length ?? 0)) {
        base.supportFormats = unlocked.supportFormats;
      }
      final uq = unlocked.acceptQuality;
      if (uq != null && uq.length > (base.acceptQuality?.length ?? 0)) {
        // 过滤未知码值并保持 accept_description 一一对应
        final validCodes = {for (final qa in VideoQuality.values) qa.code};
        final ud = unlocked.acceptDesc;
        final pairs = <int, dynamic>{
          for (var i = 0; i < uq.length; i++)
            if (validCodes.contains(uq[i]))
              uq[i]: (ud != null && i < ud.length) ? ud[i] : null,
        };
        if (pairs.length > (base.acceptQuality?.length ?? 0)) {
          base.acceptQuality = pairs.keys.toList()
            ..sort((a, b) => b.compareTo(a));
          base.acceptDesc = [for (final qn in base.acceptQuality!) pairs[qn]];
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 番剧解锁:
  /// - 会员剧集(试看): 经服务器解析整集, 返回完整 PlayUrlModel 用于整体替换试看数据
  /// - 免费剧集: 仅合并更高画质(原地修改 base, 返回 null)
  /// 任何失败 fail-open(返回 null, 保持原有试看/画质不变)。
  static Future<PlayUrlModel?> resolvePgcReplacement({
    String? bvid,
    required int cid,
    dynamic epid,
    dynamic seasonId,
    required int qn,
    required PlayUrlModel base,
  }) async {
    if (!canUse) return null;
    try {
      final isPreview = base.acceptDesc?.contains('试看') == true;
      if (!isPreview) {
        await unlockHighest(
          videoType: .pgc,
          bvid: bvid,
          cid: cid,
          epid: epid,
          seasonId: seasonId,
          tryLook: false,
          base: base,
        );
        return null;
      }
      final envelope = await resolvePlayUrl(
        videoType: .pgc,
        bvid: bvid,
        cid: cid,
        epid: epid,
        seasonId: seasonId,
        tryLook: false,
        qn: qn,
      );
      if (envelope == null) return null;
      final payload = _payloadOf(.pgc, envelope);
      if (payload == null) return null;
      _stripFlags(payload);
      final full = PlayUrlModel.fromJson(payload);
      final videoList = full.dash?.video;
      if (videoList == null || videoList.isEmpty) return null;
      // 保留试看阶段的续播进度
      full.lastPlayTime = base.lastPlayTime;
      return full;
    } catch (_) {
      return null;
    }
  }

  /// 自动解析可用的最高一档会员画质并合并进 [base]（静默，失败不影响播放）
  static Future<void> unlockHighest({
    required VideoType videoType,
    int? avid,
    String? bvid,
    required int cid,
    dynamic epid,
    dynamic seasonId,
    required bool tryLook,
    String? language,
    bool voiceBalance = false,
    required PlayUrlModel base,
  }) async {
    if (!canUse || base.dash?.video == null) return;
    try {
      final knownQn = <int>{
        for (final item in base.dash!.video!) if (item.id != null) item.id!,
      };
      final validCodes = {for (final qa in VideoQuality.values) qa.code};
      final candidates = <int>{
        ...?base.supportFormats?.map((e) => e.quality).whereType<int>(),
        ...?base.acceptQuality,
      }..removeWhere((qn) => knownQn.contains(qn) || !validCodes.contains(qn));
      if (candidates.isEmpty) return;
      final highest = candidates.reduce(max);
      final envelope = await resolvePlayUrl(
        videoType: videoType,
        avid: avid,
        bvid: bvid,
        cid: cid,
        epid: epid,
        seasonId: seasonId,
        tryLook: tryLook,
        language: language,
        voiceBalance: voiceBalance,
        qn: highest,
        silent: true,
      ).timeout(const Duration(seconds: 8), onTimeout: () => null);
      if (envelope != null) {
        mergeInto(base, envelope, videoType);
      }
    } catch (_) {}
  }
}
