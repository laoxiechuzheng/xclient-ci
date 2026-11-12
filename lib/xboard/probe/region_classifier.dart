const _regions = <String, List<String>>{
  'HK': ['🇭🇰', '香港', 'hong kong', 'hongkong', 'hk', 'hkg'],
  'TW': ['🇹🇼', '台湾', '台灣', 'taiwan', 'taipei', 'tw', 'twn'],
  'JP': [
    '🇯🇵',
    '日本',
    '东京',
    '東京',
    '大阪',
    'japan',
    'tokyo',
    'osaka',
    'jp',
    'jpn',
  ],
  'SG': ['🇸🇬', '新加坡', '狮城', '獅城', 'singapore', 'sg', 'sgp'],
  'KR': [
    '🇰🇷',
    '韩国',
    '韓國',
    '首尔',
    '首爾',
    'south korea',
    'seoul',
    'korea',
    'kr',
    'kor',
  ],
  'US': [
    '🇺🇸',
    '美国',
    '美國',
    '洛杉矶',
    '纽约',
    'united states',
    'america',
    'los angeles',
    'new york',
    'us',
    'usa',
  ],
  'DE': ['🇩🇪', '德国', '德國', '法兰克福', 'germany', 'frankfurt', 'de', 'deu'],
  'CA': ['🇨🇦', '加拿大', 'canada', 'toronto', 'vancouver', 'ca', 'can'],
  'GB': [
    '🇬🇧',
    '英国',
    '英國',
    '伦敦',
    'united kingdom',
    'britain',
    'london',
    'uk',
    'gb',
    'gbr',
  ],
  'FR': ['🇫🇷', '法国', '法國', '巴黎', 'france', 'paris', 'fr', 'fra'],
  'AU': [
    '🇦🇺',
    '澳大利亚',
    '澳大利亞',
    '澳洲',
    '悉尼',
    'australia',
    'sydney',
    'au',
    'aus',
  ],
  'NL': ['🇳🇱', '荷兰', '荷蘭', 'netherlands', 'amsterdam', 'nl', 'nld'],
  'RU': ['🇷🇺', '俄罗斯', '俄羅斯', 'russia', 'moscow', 'ru', 'rus'],
  'IN': ['🇮🇳', '印度', 'india', 'mumbai', 'in', 'ind'],
  'MY': ['🇲🇾', '马来西亚', '馬來西亞', 'malaysia', 'my', 'mys'],
  'TH': ['🇹🇭', '泰国', '泰國', 'thailand', 'bangkok', 'th', 'tha'],
  'VN': ['🇻🇳', '越南', 'vietnam', 'vn', 'vnm'],
  'PH': ['🇵🇭', '菲律宾', '菲律賓', 'philippines', 'ph', 'phl'],
  'ID': ['🇮🇩', '印度尼西亚', '印尼', 'indonesia', 'id', 'idn'],
  'TR': ['🇹🇷', '土耳其', 'turkey', 'istanbul', 'tr', 'tur'],
  'CH': ['🇨🇭', '瑞士', 'switzerland', 'zurich', 'ch', 'che'],
  'MO': ['🇲🇴', '澳门', '澳門', 'macao', 'macau', 'mo', 'mac'],
  'BR': ['🇧🇷', '巴西', 'brazil', 'br', 'bra'],
};

final _ascii = RegExp(r'^[a-z ]+$');
final _tokens = <String, RegExp>{
  for (final aliases in _regions.values)
    for (final alias in aliases)
      if (_ascii.hasMatch(alias))
        alias: RegExp('(^|[^a-z])${RegExp.escape(alias)}([^a-z]|\$)'),
};

String? classifyRegion(String name) {
  final value = name.toLowerCase();
  for (final entry in _regions.entries) {
    if (value.contains(entry.value.first)) return entry.key;
  }
  String? matched;
  var longest = 0;
  for (final entry in _regions.entries) {
    for (final alias in entry.value.skip(1)) {
      if (alias.length <= longest) continue;
      if (_ascii.hasMatch(alias)
          ? _tokens[alias]!.hasMatch(value)
          : value.contains(alias)) {
        matched = entry.key;
        longest = alias.length;
      }
    }
  }
  return matched;
}
