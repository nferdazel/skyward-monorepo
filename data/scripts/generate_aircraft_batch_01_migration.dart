import 'dart:io';

void main() {
  final rows = _readCsv('data/curated/aircraft_replenishment_batch_01_reviewed.csv');
  if (rows.length <= 1) {
    stderr.writeln('No reviewed aircraft batch rows found.');
    exitCode = 1;
    return;
  }

  final output = File('migrations/29_aircraft_replenishment_batch_01.sql');
  final dataRows = rows.skip(1).toList();
  final sourceRows = dataRows
      .map(
        (row) =>
            "  ('${_escape(row[0])}', '${_escape(row[1])}', '${_escape(row[2])}', ${row[3]}, ${row[4]}, ${row[5]}, ${row[6]}, ${row[7]}, ${row[8]}, ${row[9]})",
      )
      .join(',\n');

  final buffer = StringBuffer()
    ..writeln('-- ============================================================================')
    ..writeln('-- SKYWARD AIRCRAFT REPLENISHMENT BATCH 01')
    ..writeln('-- ============================================================================')
    ..writeln('-- Generated from data/curated/aircraft_replenishment_batch_01_reviewed.csv')
    ..writeln('-- Scope: missing modern passenger-commercial aircraft families and')
    ..writeln('-- notable adjacent variants that fit the existing game economy model.')
    ..writeln('-- ============================================================================')
    ..writeln()
    ..writeln('WITH source_rows (')
    ..writeln('  manufacturer,')
    ..writeln('  model_name,')
    ..writeln('  type,')
    ..writeln('  range_km,')
    ..writeln('  capacity,')
    ..writeln('  speed_kmh,')
    ..writeln('  fuel_burn_per_km,')
    ..writeln('  maintenance_cost_per_hour,')
    ..writeln('  purchase_price,')
    ..writeln('  lease_price_per_month')
    ..writeln(') AS (')
    ..writeln('VALUES')
    ..writeln(sourceRows)
    ..writeln(')')
    ..writeln('UPDATE aircraft_models AS target')
    ..writeln('SET')
    ..writeln('  type = source.type,')
    ..writeln('  range_km = source.range_km,')
    ..writeln('  capacity = source.capacity,')
    ..writeln('  speed_kmh = source.speed_kmh,')
    ..writeln('  fuel_burn_per_km = source.fuel_burn_per_km,')
    ..writeln('  maintenance_cost_per_hour = source.maintenance_cost_per_hour,')
    ..writeln('  purchase_price = source.purchase_price,')
    ..writeln('  lease_price_per_month = source.lease_price_per_month')
    ..writeln('FROM source_rows AS source')
    ..writeln('WHERE target.manufacturer = source.manufacturer')
    ..writeln('  AND target.model_name = source.model_name;')
    ..writeln()
    ..writeln('WITH source_rows (')
    ..writeln('  manufacturer,')
    ..writeln('  model_name,')
    ..writeln('  type,')
    ..writeln('  range_km,')
    ..writeln('  capacity,')
    ..writeln('  speed_kmh,')
    ..writeln('  fuel_burn_per_km,')
    ..writeln('  maintenance_cost_per_hour,')
    ..writeln('  purchase_price,')
    ..writeln('  lease_price_per_month')
    ..writeln(') AS (')
    ..writeln('VALUES')
    ..writeln(sourceRows)
    ..writeln(')')
    ..writeln('INSERT INTO aircraft_models (')
    ..writeln('  manufacturer,')
    ..writeln('  model_name,')
    ..writeln('  type,')
    ..writeln('  range_km,')
    ..writeln('  capacity,')
    ..writeln('  speed_kmh,')
    ..writeln('  fuel_burn_per_km,')
    ..writeln('  maintenance_cost_per_hour,')
    ..writeln('  purchase_price,')
    ..writeln('  lease_price_per_month')
    ..writeln(')')
    ..writeln('SELECT')
    ..writeln('  source.manufacturer,')
    ..writeln('  source.model_name,')
    ..writeln('  source.type,')
    ..writeln('  source.range_km,')
    ..writeln('  source.capacity,')
    ..writeln('  source.speed_kmh,')
    ..writeln('  source.fuel_burn_per_km,')
    ..writeln('  source.maintenance_cost_per_hour,')
    ..writeln('  source.purchase_price,')
    ..writeln('  source.lease_price_per_month')
    ..writeln('FROM source_rows AS source')
    ..writeln('WHERE NOT EXISTS (')
    ..writeln('  SELECT 1')
    ..writeln('  FROM aircraft_models AS target')
    ..writeln('  WHERE target.manufacturer = source.manufacturer')
    ..writeln('    AND target.model_name = source.model_name')
    ..writeln(');');

  output.writeAsStringSync(buffer.toString());
  stdout.writeln('Wrote ${dataRows.length} aircraft upserts to ${output.path}.');
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
