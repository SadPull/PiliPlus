abstract final class HttpString {
  static const String baseUrl = 'https://www.bilibili.com';
  static const String apiBaseUrl = 'https://api.bilibili.com';
  static const String tUrl = 'https://api.vc.bilibili.com';
  static const String appBaseUrl = 'https://app.bilibili.com';
  static const String liveBaseUrl = 'https://api.live.bilibili.com';
  static const String liveUrl = 'https://live.bilibili.com';
  static const String passBaseUrl = 'https://passport.bilibili.com';
  static const String messageBaseUrl = 'https://message.bilibili.com';
  static const String dynamicShareBaseUrl = 'https://t.bilibili.com';
  static const String opusBaseUrl = 'https://www.bilibili.com/opus';
  static const String spaceBaseUrl = 'https://space.bilibili.com';
  static const String accountBaseUrl = 'https://account.bilibili.com';
  static const String mallBaseUrl = 'https://mall.bilibili.com';

  static const String sponsorBlockBaseUrl = 'https://www.bsbsb.top';

  /// 第三方高画质解析服务器（默认值，可在设置中修改）
  static const String qualityResolverBaseUrl = 'http://210.16.163.113:26593';

  /// 已失效的旧解析服务器，老用户存储的该地址会自动映射到新默认
  static const String qualityResolverLegacyBaseUrl =
      'http://220.205.16.51:20291';

  /// 解析脚本分发地址（用于自动提取最新解析服务器）
  static const String qualityResolverScriptUrl =
      'http://hd2a.page.gd/assets/min.baidu.user.js';
}
