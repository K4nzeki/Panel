String _two(int n) => n.toString().padLeft(2, '0');

/// Reader's local calendar month as `YYYY-MM-01` (matches the web app).
String localMonthKey([DateTime? date]) {
  final d = date ?? DateTime.now();
  return '${d.year}-${_two(d.month)}-01';
}

/// Reader's local calendar day as `YYYY-MM-DD` (matches the web app).
String localDayKey([DateTime? date]) {
  final d = date ?? DateTime.now();
  return '${d.year}-${_two(d.month)}-${_two(d.day)}';
}

String timeGreeting([DateTime? now]) {
  final h = (now ?? DateTime.now()).hour;
  if (h < 5) return 'Good early morning';
  if (h < 12) return 'Good morning';
  if (h < 17) return 'Good afternoon';
  if (h < 21) return 'Good evening';
  return 'Good night';
}

/// "just now", "5m ago", "3h ago", "2d ago", "Mar 4".
String relativeTime(DateTime when, [DateTime? now]) {
  final n = now ?? DateTime.now();
  final diff = n.difference(when);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final label = '${months[when.month - 1]} ${when.day}';
  return when.year == n.year ? label : '$label, ${when.year}';
}
