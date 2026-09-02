import 'package:equatable/equatable.dart';

import '../../../core/constants/game_constants.dart';

class AircraftModel with Equatable {
  final String id;
  final String manufacturer;
  final String modelName;
  final String type;
  final int rangeKm;
  final int capacity;
  final int speedKmh;
  final double fuelBurnPerKm;
  final double maintenanceCostPerHour;
  final double purchasePrice;
  final double leasePricePerMonth;

  const AircraftModel({
    required this.id,
    required this.manufacturer,
    required this.modelName,
    required this.type,
    required this.rangeKm,
    required this.capacity,
    required this.speedKmh,
    required this.fuelBurnPerKm,
    required this.maintenanceCostPerHour,
    required this.purchasePrice,
    required this.leasePricePerMonth,
  });

  factory AircraftModel.fromMap(Map<String, dynamic> map) {
    return AircraftModel(
      id: map['id'] ?? '',
      manufacturer: map['manufacturer'] ?? '',
      modelName: map['model_name'] ?? '',
      type: map['type'] ?? '',
      rangeKm: (map['range_km'] as num?)?.toInt() ?? 0,
      capacity: (map['capacity'] as num?)?.toInt() ?? 0,
      speedKmh: (map['speed_kmh'] as num?)?.toInt() ?? 850,
      fuelBurnPerKm: (map['fuel_burn_per_km'] as num?)?.toDouble() ?? 0.0,
      maintenanceCostPerHour:
          (map['maintenance_cost_per_hour'] as num?)?.toDouble() ?? 0.0,
      purchasePrice: (map['purchase_price'] as num?)?.toDouble() ?? 0.0,
      leasePricePerMonth:
          (map['lease_price_per_month'] as num?)?.toDouble() ?? 0.0,
    );
  }

  @override
  List<Object?> get props => [
    id,
    manufacturer,
    modelName,
    type,
    rangeKm,
    capacity,
    speedKmh,
    fuelBurnPerKm,
    maintenanceCostPerHour,
    purchasePrice,
    leasePricePerMonth,
  ];
}

class UserFleetAircraft with Equatable {
  final String id;
  final String nickname;
  final String acquisitionType;
  final double condition;
  final String status;
  final AircraftModel model;
  final int economySeats;
  final int businessSeats;
  final int firstClassSeats;
  final String tailNumber;

  const UserFleetAircraft({
    required this.id,
    required this.nickname,
    required this.acquisitionType,
    required this.condition,
    required this.status,
    required this.model,
    this.economySeats = 0,
    this.businessSeats = 0,
    this.firstClassSeats = 0,
    this.tailNumber = '',
  });

  factory UserFleetAircraft.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic> modelMap = {};
    if (map['aircraft_models'] is Map) {
      modelMap = Map<String, dynamic>.from(map['aircraft_models'] as Map);
    } else {
      modelMap = {
        'id': map['aircraft_model_id'] ?? map['model_id'] ?? '',
        'model_name': map['model_name'] ?? '',
        'manufacturer': map['manufacturer'] ?? '',
        'range_km': map['range_km'] ?? 0,
        'capacity': map['capacity'] ?? 0,
        'speed_kmh': map['speed_kmh'] ?? 850,
        'fuel_burn_per_km': map['fuel_burn_per_km'] ?? 0.0,
        'maintenance_cost_per_hour': map['maintenance_cost_per_hour'] ?? 0.0,
        'purchase_price': map['purchase_price'] ?? 0.0,
        'lease_price_per_month': map['lease_price_per_month'] ?? 0.0,
      };
    }

    return UserFleetAircraft(
      id: (map['id'] ?? '').toString(),
      nickname: (map['nickname'] ?? '').toString(),
      acquisitionType: (map['acquisition_type'] ?? 'purchase').toString(),
      condition: (map['condition'] as num?)?.toDouble() ?? 100.0,
      status: (map['status'] ?? 'active').toString(),
      model: AircraftModel.fromMap(modelMap),
      economySeats: (map['economy_seats'] as num?)?.toInt() ?? 0,
      businessSeats: (map['business_seats'] as num?)?.toInt() ?? 0,
      firstClassSeats: (map['first_class_seats'] as num?)?.toInt() ?? 0,
      tailNumber: (map['tail_number'] ?? '').toString(),
    );
  }

  bool get isOwned => acquisitionType == 'purchase';

  double get maintenanceWearPerFlightCycle {
    return acquisitionType == 'lease'
        ? GameConstants.leasedWearPerFlightCycle
        : GameConstants.ownedWearPerFlightCycle;
  }

  bool isMaintenanceGrounded(double autoGroundingThreshold) {
    final effectiveThreshold =
        autoGroundingThreshold > GameConstants.absoluteMinimumSafetyLimit
        ? autoGroundingThreshold
        : GameConstants.absoluteMinimumSafetyLimit;
    return status == 'grounded' || condition < effectiveThreshold;
  }

  int get effectivePassengerCapacity {
    final configuredSeats = economySeats + businessSeats + firstClassSeats;
    return configuredSeats > 0 ? configuredSeats : model.capacity;
  }

  bool canOperateDistance(double distanceKm) {
    return model.rangeKm >= distanceKm.ceil();
  }

  double get estimatedSaleValue {
    if (acquisitionType != 'purchase') return 0.0;
    return model.purchasePrice * 0.72 * (condition / 100.0);
  }

  double get leaseTerminationFee {
    if (acquisitionType != 'lease') return 0.0;
    return model.leasePricePerMonth * 0.25;
  }

  // Calculate dynamic repair cost based on condition, acquisition type, and pricing
  double get repairCost {
    if (condition >= 100.0) return 0.0;
    final wearPercent = 100.0 - condition;
    if (acquisitionType == 'lease') {
      // Leased aircraft: maintenance is an operational cost proportional to lease rate
      return wearPercent * (model.leasePricePerMonth * 0.5);
    }
    // Owned aircraft: capital repair cost proportional to asset value
    return wearPercent * (model.purchasePrice * 0.0005);
  }

  @override
  List<Object?> get props => [
    id,
    nickname,
    acquisitionType,
    condition,
    status,
    model,
    economySeats,
    businessSeats,
    firstClassSeats,
    tailNumber,
  ];
}
