import 'dart:io';

void main() {
  final rows = _readCsv('data/curated/airports_replenishment_batch_01_reviewed.csv');
  if (rows.length <= 1) {
    stderr.writeln('No reviewed airport batch rows found.');
    exitCode = 1;
    return;
  }

  final output = File('migrations/28_airport_replenishment_batch_01.sql');
  final dataRows = rows.skip(1).toList();

  final buffer = StringBuffer()
    ..writeln('-- ============================================================================')
    ..writeln('-- SKYWARD AIRPORT REPLENISHMENT BATCH 01')
    ..writeln('-- ============================================================================')
    ..writeln('-- Generated from data/curated/airports_replenishment_batch_01_reviewed.csv')
    ..writeln('-- Scope: missing large scheduled-service airports within the current target')
    ..writeln('-- region footprint (Asia-Pacific and nearby commercial hubs).')
    ..writeln('-- ============================================================================')
    ..writeln()
    ..writeln('INSERT INTO airports (')
    ..writeln('  iata,')
    ..writeln('  name,')
    ..writeln('  city,')
    ..writeln('  country,')
    ..writeln('  latitude,')
    ..writeln('  longitude,')
    ..writeln('  demand_index,')
    ..writeln('  airport_tax')
    ..writeln(')')
    ..writeln('VALUES');

  for (var i = 0; i < dataRows.length; i++) {
    final row = dataRows[i];
    final suffix = i == dataRows.length - 1 ? '' : ',';
    buffer.writeln(
      "  ('${_escape(row[0])}', '${_escape(row[1])}', '${_escape(row[2])}', '${_escape(row[3])}', ${row[4]}, ${row[5]}, ${row[8]}, ${row[9]})$suffix",
    );
  }

  buffer
    ..writeln('ON CONFLICT (iata) DO UPDATE SET')
    ..writeln('  name = EXCLUDED.name,')
    ..writeln('  city = EXCLUDED.city,')
    ..writeln('  country = EXCLUDED.country,')
    ..writeln('  latitude = EXCLUDED.latitude,')
    ..writeln('  longitude = EXCLUDED.longitude,')
    ..writeln('  demand_index = EXCLUDED.demand_index,')
    ..writeln('  airport_tax = EXCLUDED.airport_tax;');

  output.writeAsStringSync(buffer.toString());
  stdout.writeln('Wrote ${dataRows.length} airport upserts to ${output.path}.');
}

List<List<String>> _readCsv(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('Missing file: $path');
    exitCode = 1;
    throw Exception('Missing file: $path');
  }

  return file
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .map(_parseCsvLine)
      .toList();
}

List<String> _parseCsvLine(String line) {
  final cells = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < line.length; i++) {
    final char = line[i];

    if (char == '"') {
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        buffer.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }

    if (char == ',' && !inQuotes) {
      cells.add(buffer.toString());
      buffer.clear();
      continue;
    }

    buffer.write(char);
  }

  cells.add(buffer.toString());
  return cells;
}

String _escape(String value) => value.replaceAll("'", "''");
