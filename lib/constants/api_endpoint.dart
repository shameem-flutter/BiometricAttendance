class ApiEndpoints {
  static String normalizeUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return url;
    if (!url.startsWith("http://") && !url.startsWith("https://")) {
      url = "http://$url";
    }
    while (url.endsWith("/")) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }
}

