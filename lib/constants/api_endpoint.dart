class ApiEndpoints {
  static String normalizeUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return url;
    if (url.startsWith("http://")) {
      url = "https://${url.substring(7)}";
    } else if (!url.startsWith("https://")) {
      url = "https://$url";
    }
    while (url.endsWith("/")) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }
}
