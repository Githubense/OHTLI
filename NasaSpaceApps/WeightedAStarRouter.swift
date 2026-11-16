import Foundation

struct RouteConstraints: Sendable {
    var operationalSlopeCutoffDegrees = 20.0
    var nominalSpeedCeilingMetersPerSecond = 1.29
    var metabolicPowerCeilingWatts = 807.0
    var minimumWalkBackMarginPercent = 50.0
    var solarShelterLimitMinutes = 30.0
    var elevatedRadiationMultiplier = 2.5
    var martianGravityMetersPerSecondSquared = 3.72076
    var emergencyBrakingReferenceSpeedMetersPerSecond = 1.15
    var scienceStopMinutes = 30.0
    var scienceStopWatts = 280.0

    // Scenario-only capacities. They are demo inputs, not suit specifications.
    var demoEnergyCapacityKilojoules = 3_000.0
    var demoOxygenDurationMinutes = 150.0
    var demoCO2ScrubberDurationMinutes = 150.0
    var demoCoolingWaterCapacityKilograms = 1.5
}

struct DemoTerrainOverlay: Sendable {
    var obstacleX = 45...55
    var obstacleY = 54...73
    var sandX = 31...79
    var sandY = 49...79
    var ridgeY = 42...47
    var thermalShadowX = 30...64
    var thermalShadowY = 84...98
    var radioShadowX = 45...55
    var radioShadowY = 54...73

    func surfaceClass(at point: GridPoint) -> SurfaceClass {
        if obstacleX.contains(point.x) && obstacleY.contains(point.y) { return .scenarioHazard }
        if ridgeY.contains(point.y) { return .cementedRidge }
        if sandX.contains(point.x) && sandY.contains(point.y) { return .looseSand }
        return .unclassified
    }

    func isThermallyShadowed(_ point: GridPoint) -> Bool {
        thermalShadowX.contains(point.x) && thermalShadowY.contains(point.y)
    }

    func hasRadioLineOfSight(_ point: GridPoint) -> Bool {
        !(radioShadowX.contains(point.x) && radioShadowY.contains(point.y))
    }
}

struct WeightedAStarRouter: Sendable {
    var constraints = RouteConstraints()
    var overlay = DemoTerrainOverlay()

    func compare(
        on grid: TerrainGrid,
        from origin: GridPoint,
        to destination: GridPoint,
        weights: RouteWeights,
        solarStormActive: Bool = false
    ) -> RouteComparison? {
        guard grid.contains(origin), grid.contains(destination), origin != destination else { return nil }
        let straightPath = Self.bresenham(from: origin, to: destination)
        let straightLineResult = assessStraightLine(path: straightPath, grid: grid, solarStormActive: solarStormActive)
        let outcome = searchAlternatives(on: grid, from: origin, to: destination, weights: weights, solarStormActive: solarStormActive)
        let result: RouteResult
        let failure: RouteFailureReason?
        switch outcome {
        case .found(let route):
            result = route
            failure = nil
        case .failed(let reason):
            failure = reason
            // A missing path must never be mistaken for a valid zero-length route.
            result = RouteResult(path: [], distanceMeters: 0, traverseMinutes: 0,
                energyKilojoules: 0, coolingWaterKilograms: 0, doseMicroSieverts: 0,
                minimumSlopeDegrees: 0, maximumSlopeDegrees: 0, emergencyBrakingDistanceMeters: 0,
                radioLineOfSightFraction: 0, walkBackMarginPercent: 0, usesScenarioOverlay: true,
                safetyViolations: [reason.message], warning: reason.message)
        }
        return RouteComparison(origin: origin, destination: destination, straightLinePath: straightPath,
            straightLineDistanceMeters: straightLineResult.distanceMeters, straightLineResult: straightLineResult,
            routed: result, isWalkBack: solarStormActive, failureReason: failure)
    }

    func route(on grid: TerrainGrid, from origin: GridPoint, to destination: GridPoint,
               weights: RouteWeights, solarStormActive: Bool = false) -> RouteResult? {
        guard case .found(let result) = searchAlternatives(on: grid, from: origin, to: destination,
                                                           weights: weights, solarStormActive: solarStormActive) else { return nil }
        return result
    }

    /// Scenario starts with 75% of each modeled capacity. These are not suit readings.
    let emergencyStartingFraction = 0.75

    func emergencyReturn(on grid: TerrainGrid, from origin: GridPoint, to airlock: GridPoint,
                         weights: RouteWeights) -> RouteComparison? {
        guard grid.contains(origin), grid.contains(airlock), origin != airlock else { return nil }
        let direct = Self.bresenham(from: origin, to: airlock)
        let directResult = assessStraightLine(path: direct, grid: grid, solarStormActive: false)
        let outcome = searchAlternatives(on: grid, from: origin, to: airlock, weights: weights,
                                         solarStormActive: false, emergency: true)
        let result: RouteResult
        let failure: RouteFailureReason?
        switch outcome {
        case .found(let route): result = route; failure = nil
        case .failed(let reason):
            failure = reason
            result = RouteResult(path: [], distanceMeters: 0, traverseMinutes: 0,
                energyKilojoules: 0, coolingWaterKilograms: 0, doseMicroSieverts: 0,
                minimumSlopeDegrees: 0, maximumSlopeDegrees: 0, emergencyBrakingDistanceMeters: 0,
                radioLineOfSightFraction: 0, walkBackMarginPercent: 0, usesScenarioOverlay: true,
                safetyViolations: [reason.message], warning: reason.message)
        }
        return RouteComparison(origin: origin, destination: airlock, straightLinePath: direct,
                               straightLineDistanceMeters: directResult.distanceMeters,
                               straightLineResult: directResult, routed: result, isWalkBack: true,
                               failureReason: failure)
    }

    func emergencyLimitingResource(for result: RouteResult) -> String {
        let reserves: [(String, Double)] = [
            ("energy", emergencyStartingFraction - result.energyKilojoules / constraints.demoEnergyCapacityKilojoules),
            ("oxygen", emergencyStartingFraction - result.traverseMinutes / constraints.demoOxygenDurationMinutes),
            ("CO₂ scrubbing", emergencyStartingFraction - result.traverseMinutes / constraints.demoCO2ScrubberDurationMinutes),
            ("cooling water", emergencyStartingFraction - result.coolingWaterKilograms / constraints.demoCoolingWaterCapacityKilograms)
        ]
        return reserves.min(by: { $0.1 < $1.1 })?.0 ?? "unknown"
    }

    private enum SearchOutcome {
        case found(RouteResult)
        case failed(RouteFailureReason)
    }
    private enum CandidateOutcome {
        case found(RouteResult)
        case rejected
        case noPath
    }

    private func searchAlternatives(on grid: TerrainGrid, from origin: GridPoint, to destination: GridPoint,
                                    weights: RouteWeights, solarStormActive: Bool, emergency: Bool = false) -> SearchOutcome {
        guard grid.contains(origin), grid.contains(destination), origin != destination,
              isPassable(origin, grid: grid), isPassable(destination, grid: grid) else { return .failed(.blockedEndpoint) }
        var rejected = false
        for resourceBias in [0.0, 1.0, 4.0, 12.0] {
            switch search(on: grid, from: origin, to: destination, weights: weights,
                          solarStormActive: solarStormActive, resourceBias: resourceBias, emergency: emergency) {
            case .found(let result): return .found(result)
            case .rejected: rejected = true
            case .noPath: return .failed(.noPassablePath)
            }
        }
        return .failed(rejected ? .candidatesRejected : .noPassablePath)
    }

    private func search(on grid: TerrainGrid, from origin: GridPoint, to destination: GridPoint, weights: RouteWeights, solarStormActive: Bool, resourceBias: Double, emergency: Bool) -> CandidateOutcome {
        let startNode = SearchNode(point: origin, cost: 0, estimate: heuristic(origin, destination, cellSize: grid.cellSizeMeters))
        var frontier = MinHeap<SearchNode>(sort: SearchNode.precedes)
        frontier.insert(startNode)
        var costTo: [GridPoint: Double] = [origin: 0]
        var cameFrom: [GridPoint: GridPoint] = [:]

        while let current = frontier.removeFirst() {
            if current.point == destination {
                guard let path = reconstructPath(from: destination, origin: origin, cameFrom: cameFrom),
                      let result = makeResult(path: path, grid: grid, solarStormActive: solarStormActive, emergency: emergency) else { return .rejected }
                return .found(result)
            }
            guard current.cost <= (costTo[current.point] ?? .infinity) else { continue }

            for next in neighbors(of: current.point, grid: grid) where canTraverse(from: current.point, to: next, grid: grid) {
                let surface = overlay.surfaceClass(at: next)
                let distance = hypot(Self.planarDistance(current.point, next) * grid.cellSizeMeters, grid.elevation(at: next) - grid.elevation(at: current.point))
                let resourceCost = distance / min(speed(for: surface), constraints.nominalSpeedCeilingMetersPerSecond) * metabolicPower(for: surface) / 420
                let edge = edgeCost(from: current.point, to: next, grid: grid, weights: weights, solarStormActive: solarStormActive) + resourceBias * resourceCost
                let tentative = current.cost + edge
                if tentative < (costTo[next] ?? .infinity) {
                    cameFrom[next] = current.point
                    costTo[next] = tentative
                    let h = heuristic(next, destination, cellSize: grid.cellSizeMeters)
                    frontier.insert(SearchNode(point: next, cost: tentative, estimate: h))
                }
            }
        }
        return .noPath
    }

    private func isPassable(_ point: GridPoint, grid: TerrainGrid) -> Bool {
        let terrainClass = overlay.surfaceClass(at: point)
        guard terrainClass != .scenarioHazard else { return false }
        let slope = localSlopeDegrees(at: point, grid: grid)
        let frictionCoefficient = frictionCoefficient(for: terrainClass)
        let frictionAngle = atan(frictionCoefficient) * 180 / .pi
        let maximumSlope = min(constraints.operationalSlopeCutoffDegrees, frictionAngle)
        return slope <= maximumSlope
    }

    private func canTraverse(from origin: GridPoint, to destination: GridPoint, grid: TerrainGrid) -> Bool {
        guard isPassable(origin, grid: grid), isPassable(destination, grid: grid) else { return false }

        let originClass = overlay.surfaceClass(at: origin)
        let destinationClass = overlay.surfaceClass(at: destination)
        let frictionLimit = min(
            atan(frictionCoefficient(for: originClass)),
            atan(frictionCoefficient(for: destinationClass))
        ) * 180 / .pi
        let horizontal = Self.planarDistance(origin, destination) * grid.cellSizeMeters
        let vertical = abs(grid.elevation(at: destination) - grid.elevation(at: origin))
        let edgeSlope = atan2(vertical, horizontal) * 180 / .pi
        guard edgeSlope <= min(constraints.operationalSlopeCutoffDegrees, frictionLimit) else { return false }

        // Prevent an eight-neighbor diagonal from cutting through the corner of a
        // blocked cell or slipping between a hard exclusion and an unsafe slope.
        let deltaX = destination.x - origin.x
        let deltaY = destination.y - origin.y
        guard deltaX != 0, deltaY != 0 else { return true }
        let horizontalStep = GridPoint(x: origin.x + deltaX, y: origin.y)
        let verticalStep = GridPoint(x: origin.x, y: origin.y + deltaY)
        return canTraverse(from: origin, to: horizontalStep, grid: grid)
            && canTraverse(from: origin, to: verticalStep, grid: grid)
            && canTraverse(from: horizontalStep, to: destination, grid: grid)
            && canTraverse(from: verticalStep, to: destination, grid: grid)
    }

    private func edgeCost(
        from origin: GridPoint,
        to destination: GridPoint,
        grid: TerrainGrid,
        weights: RouteWeights,
        solarStormActive: Bool
    ) -> Double {
        let terrainClass = overlay.surfaceClass(at: destination)
        let planarMeters = Self.planarDistance(origin, destination) * grid.cellSizeMeters
        let verticalMeters = abs(grid.elevation(at: destination) - grid.elevation(at: origin))
        let distance3D = hypot(planarMeters, verticalMeters)
        let slope = atan2(verticalMeters, planarMeters) * 180 / .pi
        let assumedSurface = terrainClass == .scenarioHazard ? SurfaceClass.looseSand : terrainClass
        let friction = frictionCoefficient(for: assumedSurface)
        let speed = min(speed(for: assumedSurface), constraints.nominalSpeedCeilingMetersPerSecond)
        let brakingSpeed = constraints.emergencyBrakingReferenceSpeedMetersPerSecond
        let brakingDistance = brakingSpeed * brakingSpeed / (2 * friction * constraints.martianGravityMetersPerSecondSquared)
        let looseSandBrakingDistance = brakingSpeed * brakingSpeed
            / (2 * frictionCoefficient(for: .looseSand) * constraints.martianGravityMetersPerSecondSquared)
        let brakingRisk = min(brakingDistance / looseSandBrakingDistance, 1)
        let power = metabolicPower(for: assumedSurface)
        let metabolicRisk = min(power / constraints.metabolicPowerCeilingWatts, 1)
        let tractionRisk = min(slope / constraints.operationalSlopeCutoffDegrees, 1)
            + (assumedSurface == .looseSand ? 0.85 : 0)
            + brakingRisk * 0.25
        let thermalRisk = overlay.isThermallyShadowed(destination) ? 1.4 : 0
        let radiationRisk = solarStormActive ? constraints.elevatedRadiationMultiplier : 1
        let communicationRisk = overlay.hasRadioLineOfSight(destination) ? 0 : 1.8
        let multiplier = 1
            + weights.metabolic * metabolicRisk
            + weights.traction * tractionRisk
            + weights.thermal * thermalRisk
            + weights.radiation * radiationRisk
            + weights.communications * communicationRisk
        // Cost the edge in traversal seconds before applying the user's risk weights.
        // This lets a longer, firm ridge corridor compete with a shorter slow-sand path.
        return (distance3D / speed) * multiplier
    }

    private func makeResult(path: [GridPoint], grid: TerrainGrid, solarStormActive: Bool, emergency: Bool = false) -> RouteResult? {
        guard path.count > 1 else { return nil }
        var distance = 0.0
        var minutes = 0.0
        var energyKJ = 0.0
        var waterKG = 0.0
        var doseMicroSieverts = 0.0
        var minimumSlope = Double.infinity
        var maximumSlope = 0.0
        var maximumBrakingDistance = 0.0
        var visibleEdges = 0

        for (origin, destination) in zip(path, path.dropFirst()) {
            let classAtDestination = overlay.surfaceClass(at: destination)
            let horizontal = Self.planarDistance(origin, destination) * grid.cellSizeMeters
            let vertical = abs(grid.elevation(at: destination) - grid.elevation(at: origin))
            let edgeDistance = hypot(horizontal, vertical)
            let slope = atan2(vertical, horizontal) * 180 / .pi
            let speed = min(speed(for: classAtDestination), constraints.nominalSpeedCeilingMetersPerSecond)
            let power = metabolicPower(for: classAtDestination)
            guard speed > 0, power <= constraints.metabolicPowerCeilingWatts else { return nil }

            let edgeMinutes = edgeDistance / speed / 60
            distance += edgeDistance
            minutes += edgeMinutes
            energyKJ += power * edgeMinutes * 60 / 1_000
            waterKG += power * edgeMinutes * 60 / 1_000 / 2_480
            doseMicroSieverts += 26.7 * (edgeMinutes / 60)
                * (solarStormActive ? constraints.elevatedRadiationMultiplier : 1)
            minimumSlope = min(minimumSlope, slope)
            maximumSlope = max(maximumSlope, slope)
            let friction = frictionCoefficient(for: classAtDestination)
            maximumBrakingDistance = max(
                maximumBrakingDistance,
                constraints.emergencyBrakingReferenceSpeedMetersPerSecond
                    * constraints.emergencyBrakingReferenceSpeedMetersPerSecond
                    / (2 * friction * constraints.martianGravityMetersPerSecondSquared)
            )
            if overlay.hasRadioLineOfSight(destination) { visibleEdges += 1 }
        }

        let reservePercent: Double
        if emergency {
            // One-way return only: no science stop and no return to the crew's departure.
            reservePercent = min(emergencyStartingFraction - energyKJ / constraints.demoEnergyCapacityKilojoules,
                                 emergencyStartingFraction - minutes / constraints.demoOxygenDurationMinutes,
                                 emergencyStartingFraction - minutes / constraints.demoCO2ScrubberDurationMinutes,
                                 emergencyStartingFraction - waterKG / constraints.demoCoolingWaterCapacityKilograms) * 100
            guard reservePercent >= 0 else { return nil }
        } else {
            guard let modeledReserve = minimumReturnReserve(path: path, grid: grid),
                  modeledReserve >= constraints.minimumWalkBackMarginPercent else { return nil }
            reservePercent = modeledReserve
        }

        return RouteResult(
            path: path,
            distanceMeters: distance,
            traverseMinutes: minutes,
            energyKilojoules: energyKJ,
            coolingWaterKilograms: waterKG,
            doseMicroSieverts: doseMicroSieverts,
            minimumSlopeDegrees: minimumSlope.isFinite ? minimumSlope : 0,
            maximumSlopeDegrees: maximumSlope,
            emergencyBrakingDistanceMeters: maximumBrakingDistance,
            radioLineOfSightFraction: Double(visibleEdges) / Double(max(1, path.count - 1)),
            walkBackMarginPercent: reservePercent,
            usesScenarioOverlay: true,
            safetyViolations: [],
            warning: solarStormActive ? "Storm shelter availability is not modeled; radiation inputs are scenario-only." : nil
        )
    }

    // Reverse Dijkstra finds a traversable return path from every reachable waypoint.
    // The single return path minimizes modeled walking energy; its time and water
    // are evaluated together, so these are a feasible budget, not independent minima.
    private func minimumReturnReserve(path: [GridPoint], grid: TerrainGrid) -> Double? {
        guard let airlock = path.first else { return nil }
        var frontier = MinHeap<SearchNode>(sort: SearchNode.precedes)
        frontier.insert(SearchNode(point: airlock, cost: 0, estimate: 0))
        var returnEnergy: [GridPoint: Double] = [airlock: 0]
        var returnMinutes: [GridPoint: Double] = [airlock: 0]
        let needed = Set(path)
        var found = Set<GridPoint>()
        while let current = frontier.removeFirst() {
            guard current.cost <= (returnEnergy[current.point] ?? .infinity) else { continue }
            if needed.contains(current.point) { found.insert(current.point) }
            if found.count == needed.count { break }
            for previous in neighbors(of: current.point, grid: grid) where canTraverse(from: previous, to: current.point, grid: grid) {
                let surface = overlay.surfaceClass(at: current.point)
                let speed = min(speed(for: surface), constraints.nominalSpeedCeilingMetersPerSecond)
                let power = metabolicPower(for: surface)
                guard speed > 0, power <= constraints.metabolicPowerCeilingWatts else { continue }
                let horizontal = Self.planarDistance(previous, current.point) * grid.cellSizeMeters
                let distance = hypot(horizontal, grid.elevation(at: current.point) - grid.elevation(at: previous))
                let seconds = distance / speed
                let energy = current.cost + seconds * power / 1_000
                if energy < (returnEnergy[previous] ?? .infinity) {
                    returnEnergy[previous] = energy
                    returnMinutes[previous] = (returnMinutes[current.point] ?? 0) + seconds / 60
                    frontier.insert(SearchNode(point: previous, cost: energy, estimate: 0))
                }
            }
        }
        var outboundEnergy = 0.0
        var outboundMinutes = 0.0
        var minimumReserve = Double.infinity
        let stopEnergy = constraints.scienceStopWatts * constraints.scienceStopMinutes * 60 / 1_000
        for index in path.indices {
            if index > 0 {
                let previous = path[index - 1], point = path[index]
                let surface = overlay.surfaceClass(at: point)
                let speed = min(speed(for: surface), constraints.nominalSpeedCeilingMetersPerSecond)
                guard speed > 0 else { return nil }
                let distance = hypot(Self.planarDistance(previous, point) * grid.cellSizeMeters,
                                     grid.elevation(at: point) - grid.elevation(at: previous))
                let seconds = distance / speed
                outboundMinutes += seconds / 60
                outboundEnergy += seconds * metabolicPower(for: surface) / 1_000
            }
            guard let backEnergy = returnEnergy[path[index]], let backMinutes = returnMinutes[path[index]] else { return nil }
            // The planned science stop is charged at the destination, where it occurs.
            let stop = index == path.count - 1
            let totalEnergy = outboundEnergy + backEnergy + (stop ? stopEnergy : 0)
            let totalMinutes = outboundMinutes + backMinutes + (stop ? constraints.scienceStopMinutes : 0)
            let reserve = min(1 - totalEnergy / constraints.demoEnergyCapacityKilojoules,
                              1 - totalMinutes / constraints.demoOxygenDurationMinutes,
                              1 - totalMinutes / constraints.demoCO2ScrubberDurationMinutes,
                              1 - (totalEnergy / 2_480) / constraints.demoCoolingWaterCapacityKilograms)
            minimumReserve = min(minimumReserve, reserve * 100)
        }
        return minimumReserve
    }

    private func assessStraightLine(
        path: [GridPoint],
        grid: TerrainGrid,
        solarStormActive: Bool
    ) -> RouteResult {
        var violations = Set<String>()
        var distance = 0.0
        var minutes = 0.0
        var energyKJ = 0.0
        var waterKG = 0.0
        var doseMicroSieverts = 0.0
        var minimumSlope = Double.infinity
        var maximumSlope = 0.0
        var maximumBrakingDistance = 0.0
        var visibleEdges = 0

        for (origin, destination) in zip(path, path.dropFirst()) {
            let reportedClass = overlay.surfaceClass(at: destination)
            if reportedClass == .scenarioHazard {
                violations.insert("crosses synthetic obstacle overlay")
            }
            let surface = reportedClass == .scenarioHazard ? SurfaceClass.looseSand : reportedClass
            let horizontal = Self.planarDistance(origin, destination) * grid.cellSizeMeters
            let vertical = abs(grid.elevation(at: destination) - grid.elevation(at: origin))
            let edgeDistance = hypot(horizontal, vertical)
            let edgeSlope = atan2(vertical, horizontal) * 180 / .pi
            let localSlope = localSlopeDegrees(at: destination, grid: grid)
            let friction = frictionCoefficient(for: surface)
            let frictionAngle = atan(friction) * 180 / .pi
            if localSlope > frictionAngle || edgeSlope > frictionAngle {
                violations.insert("exceeds surface friction angle")
            }
            if localSlope > constraints.operationalSlopeCutoffDegrees || edgeSlope > constraints.operationalSlopeCutoffDegrees {
                violations.insert("exceeds demo 20° slope cutoff")
            }

            let speed = min(speed(for: surface), constraints.nominalSpeedCeilingMetersPerSecond)
            let power = metabolicPower(for: surface)
            if power > constraints.metabolicPowerCeilingWatts {
                violations.insert("exceeds demo SWME power ceiling")
            }
            let brakingSpeed = constraints.emergencyBrakingReferenceSpeedMetersPerSecond
            let stoppingDistance = brakingSpeed * brakingSpeed / (2 * friction * constraints.martianGravityMetersPerSecondSquared)
            maximumBrakingDistance = max(maximumBrakingDistance, stoppingDistance)
            let edgeMinutes = edgeDistance / speed / 60
            distance += edgeDistance
            minutes += edgeMinutes
            energyKJ += power * edgeMinutes * 60 / 1_000
            waterKG += power * edgeMinutes * 60 / 1_000 / 2_480
            doseMicroSieverts += 26.7 * (edgeMinutes / 60)
                * (solarStormActive ? constraints.elevatedRadiationMultiplier : 1)
            minimumSlope = min(minimumSlope, edgeSlope)
            maximumSlope = max(maximumSlope, edgeSlope)
            if overlay.hasRadioLineOfSight(destination) { visibleEdges += 1 }
        }

        let stopEnergyKJ = constraints.scienceStopWatts * constraints.scienceStopMinutes * 60 / 1_000
        let energyReserve = 1 - ((energyKJ * 2 + stopEnergyKJ) / constraints.demoEnergyCapacityKilojoules)
        let oxygenReserve = 1 - ((minutes * 2 + constraints.scienceStopMinutes) / constraints.demoOxygenDurationMinutes)
        let co2Reserve = 1 - ((minutes * 2 + constraints.scienceStopMinutes) / constraints.demoCO2ScrubberDurationMinutes)
        let waterReserve = 1 - ((waterKG * 2 + stopEnergyKJ / 2_480) / constraints.demoCoolingWaterCapacityKilograms)
        let reservePercent = min(energyReserve, oxygenReserve, co2Reserve, waterReserve) * 100
        if reservePercent < constraints.minimumWalkBackMarginPercent {
            violations.insert("falls below demo 50% walk-back reserve")
        }

        let sortedViolations = violations.sorted()
        return RouteResult(
            path: path,
            distanceMeters: distance,
            traverseMinutes: minutes,
            energyKilojoules: energyKJ,
            coolingWaterKilograms: waterKG,
            doseMicroSieverts: doseMicroSieverts,
            minimumSlopeDegrees: minimumSlope.isFinite ? minimumSlope : 0,
            maximumSlopeDegrees: maximumSlope,
            emergencyBrakingDistanceMeters: maximumBrakingDistance,
            radioLineOfSightFraction: Double(visibleEdges) / Double(max(1, path.count - 1)),
            walkBackMarginPercent: reservePercent,
            usesScenarioOverlay: true,
            safetyViolations: sortedViolations,
            warning: sortedViolations.isEmpty ? nil : sortedViolations.joined(separator: "; ")
        )
    }

    private func frictionCoefficient(for terrainClass: SurfaceClass) -> Double {
        switch terrainClass {
        case .looseSand: 0.25
        case .cementedRidge: 0.55
        case .unclassified: 0.40
        case .scenarioHazard: 0.25
        }
    }

    private func localSlopeDegrees(at point: GridPoint, grid: TerrainGrid) -> Double {
        let leftPoint = GridPoint(x: max(0, point.x - 1), y: point.y)
        let rightPoint = GridPoint(x: min(grid.width - 1, point.x + 1), y: point.y)
        let upPoint = GridPoint(x: point.x, y: max(0, point.y - 1))
        let downPoint = GridPoint(x: point.x, y: min(grid.height - 1, point.y + 1))
        let left = grid.elevation(at: leftPoint)
        let right = grid.elevation(at: rightPoint)
        let up = grid.elevation(at: upPoint)
        let down = grid.elevation(at: downPoint)
        let xSpan = Double(rightPoint.x - leftPoint.x) * grid.cellSizeMeters
        let ySpan = Double(downPoint.y - upPoint.y) * grid.cellSizeMeters
        let dx = xSpan > 0 ? (right - left) / xSpan : 0
        let dy = ySpan > 0 ? (down - up) / ySpan : 0
        return atan(hypot(dx, dy)) * 180 / .pi
    }

    private func speed(for terrainClass: SurfaceClass) -> Double {
        switch terrainClass {
        case .cementedRidge: 1.15
        case .looseSand: 0.55
        case .unclassified: 0.85
        case .scenarioHazard: 0
        }
    }

    private func metabolicPower(for terrainClass: SurfaceClass) -> Double {
        switch terrainClass {
        case .cementedRidge: 330
        case .looseSand: 540
        case .unclassified: 420
        case .scenarioHazard: .infinity
        }
    }

    private func neighbors(of point: GridPoint, grid: TerrainGrid) -> [GridPoint] {
        let offsets = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
        return offsets.map { GridPoint(x: point.x + $0.0, y: point.y + $0.1) }
            .filter(grid.contains)
            .sorted()
    }

    private func heuristic(_ lhs: GridPoint, _ rhs: GridPoint, cellSize: Double) -> Double {
        // The nominal ceiling is the fastest modeled speed, so this remains a lower bound
        // in the same time units as edgeCost.
        Self.planarDistance(lhs, rhs) * cellSize / constraints.nominalSpeedCeilingMetersPerSecond
    }

    private func reconstructPath(from end: GridPoint, origin: GridPoint, cameFrom: [GridPoint: GridPoint]) -> [GridPoint]? {
        var path = [end]
        var current = end
        while current != origin {
            guard let previous = cameFrom[current] else { return nil }
            current = previous
            path.append(current)
        }
        return path.reversed()
    }

    private static func planarDistance(_ lhs: GridPoint, _ rhs: GridPoint) -> Double {
        hypot(Double(lhs.x - rhs.x), Double(lhs.y - rhs.y))
    }

    private static func bresenham(from start: GridPoint, to end: GridPoint) -> [GridPoint] {
        var points: [GridPoint] = []
        var x = start.x
        var y = start.y
        let dx = abs(end.x - start.x)
        let sx = start.x < end.x ? 1 : -1
        let dy = -abs(end.y - start.y)
        let sy = start.y < end.y ? 1 : -1
        var error = dx + dy
        while true {
            points.append(GridPoint(x: x, y: y))
            if x == end.x && y == end.y { break }
            let doubled = 2 * error
            if doubled >= dy { error += dy; x += sx }
            if doubled <= dx { error += dx; y += sy }
        }
        return points
    }
}

private struct SearchNode {
    var point: GridPoint
    var cost: Double
    var estimate: Double

    nonisolated static func precedes(_ lhs: SearchNode, _ rhs: SearchNode) -> Bool {
        let left = lhs.cost + lhs.estimate
        let right = rhs.cost + rhs.estimate
        if abs(left - right) > 0.000_001 { return left < right }
        if abs(lhs.cost - rhs.cost) > 0.000_001 { return lhs.cost < rhs.cost }
        return lhs.point < rhs.point
    }
}

private struct MinHeap<Element> {
    private var elements: [Element] = []
    private let sort: (Element, Element) -> Bool

    init(sort: @escaping (Element, Element) -> Bool) { self.sort = sort }

    mutating func insert(_ value: Element) {
        elements.append(value)
        siftUp(from: elements.count - 1)
    }

    mutating func removeFirst() -> Element? {
        guard !elements.isEmpty else { return nil }
        if elements.count == 1 { return elements.removeLast() }
        let first = elements[0]
        elements[0] = elements.removeLast()
        siftDown(from: 0)
        return first
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        var parent = (child - 1) / 2
        while child > 0 && sort(elements[child], elements[parent]) {
            elements.swapAt(child, parent)
            child = parent
            parent = (child - 1) / 2
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var candidate = parent
            if left < elements.count && sort(elements[left], elements[candidate]) { candidate = left }
            if right < elements.count && sort(elements[right], elements[candidate]) { candidate = right }
            if candidate == parent { return }
            elements.swapAt(parent, candidate)
            parent = candidate
        }
    }
}
