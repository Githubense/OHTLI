import Foundation
import RealityKit
import UIKit

struct MarsDataAsset: Sendable {
    var terrain: TerrainGrid
    var metadata: TerrainMetadata
    var detailedTerrain: TerrainGrid?
    var detailedMetadata: TerrainMetadata?
    var nativeTerrain: TerrainGrid?
}

enum MarsDataCatalog {
    static func loadBundled() throws -> MarsDataAsset {
        let (terrain, metadata) = try loadGrid(dataName: "hirise_gale_context", metadataName: "terrain_metadata")
        let detailed = try? loadGrid(dataName: "hirise_gale_detail", metadataName: "terrain_detail_metadata")
        let native = try? loadGrid(dataName: "hirise_gale_native", metadataName: "terrain_native_metadata")
        return MarsDataAsset(
            terrain: terrain,
            metadata: metadata,
            detailedTerrain: detailed?.0,
            detailedMetadata: detailed?.1,
            nativeTerrain: native?.0
        )
    }

    private static func loadGrid(dataName: String, metadataName: String) throws -> (TerrainGrid, TerrainMetadata) {
        guard let dataURL = resourceURL(named: dataName, extension: "f32"),
              let metadataURL = resourceURL(named: metadataName, extension: "json") else {
            throw CatalogError.missingBundledTerrain
        }

        let metadata = try JSONDecoder().decode(TerrainMetadata.self, from: Data(contentsOf: metadataURL))
        let data = try Data(contentsOf: dataURL)
        let count = metadata.gridSize * metadata.gridSize
        guard data.count == count * MemoryLayout<UInt32>.size else {
            throw CatalogError.invalidGridByteCount(expected: count * 4, actual: data.count)
        }

        var heights: [Float] = []
        heights.reserveCapacity(count)
        for offset in stride(from: 0, to: data.count, by: 4) {
            let bits = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            heights.append(Float(bitPattern: bits))
        }

        return (
            TerrainGrid(
                width: metadata.gridSize,
                height: metadata.gridSize,
                cellSizeMeters: metadata.gridSpacingMeters,
                elevationsMeters: heights,
                sourceProduct: metadata.sourceProduct
            ),
            metadata
        )
    }

    private static func resourceURL(named name: String, extension fileExtension: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "MarsData")
            ?? Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "Resources/MarsData")
            ?? Bundle.main.url(forResource: name, withExtension: fileExtension)
    }

    enum CatalogError: Error, LocalizedError {
        case missingBundledTerrain
        case invalidGridByteCount(expected: Int, actual: Int)
        case couldNotBuildSlopeOverlay

        var errorDescription: String? {
            switch self {
            case .missingBundledTerrain:
                "The bundled HiRISE terrain grid or provenance file is missing."
            case let .invalidGridByteCount(expected, actual):
                "Expected \(expected) terrain bytes, found \(actual)."
            case .couldNotBuildSlopeOverlay:
                "The slope overlay image could not be created from the bundled DTM."
            }
        }
    }
}

nonisolated struct TerrainMeshData: Sendable {
    var vertices: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var textureCoordinates: [SIMD2<Float>]
    var indices: [UInt32]
}

nonisolated struct HorizonSkirtMeshData: Sendable {
    var vertices: [SIMD3<Float>]
    var indices: [UInt32]
}

nonisolated struct SkyHemisphereMeshData: Sendable {
    var vertices: [SIMD3<Float>]
    var textureCoordinates: [SIMD2<Float>]
    var indices: [UInt32]
}

enum TerrainMeshFactory {
    /// Upper half of an equirectangular sky dome. Keeping the lower hemisphere
    /// out of the mesh prevents the panorama's dark lower half from enclosing
    /// the wearer and appearing as a huge terrain bowl.
    nonisolated static func makeSkyHemisphereData(
        radius: Float = 30_000,
        longitudeSegments: Int = 128,
        latitudeSegments: Int = 32
    ) -> SkyHemisphereMeshData {
        let columns = max(16, longitudeSegments)
        let rows = max(4, latitudeSegments)
        var vertices: [SIMD3<Float>] = []
        var textureCoordinates: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity((columns + 1) * (rows + 1))
        textureCoordinates.reserveCapacity((columns + 1) * (rows + 1))
        indices.reserveCapacity(columns * rows * 6)
        for row in 0...rows {
            let fraction = Float(row) / Float(rows)
            let latitude = fraction * (.pi / 2)
            let ringRadius = cos(latitude) * radius
            let y = sin(latitude) * radius
            for column in 0...columns {
                let u = Float(column) / Float(columns)
                let longitude = u * 2 * .pi
                vertices.append(SIMD3(ringRadius * cos(longitude), y, ringRadius * sin(longitude)))
                textureCoordinates.append(SIMD2(u, 0.5 * (1 - fraction)))
            }
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let lower = UInt32(row * (columns + 1) + column)
                let upper = lower + UInt32(columns + 1)
                indices.append(contentsOf: [lower, upper, lower + 1, lower + 1, upper, upper + 1])
            }
        }
        return SkyHemisphereMeshData(vertices: vertices, textureCoordinates: textureCoordinates, indices: indices)
    }

    /// Places the disk below every DEM post so valleys cannot intersect the base.
    nonisolated static func tabletopBaseCenterY(grid: TerrainGrid, heightScale: Float, thickness: Float = 0.035, clearance: Float = 0.003) -> Float {
        let center = Float(grid.elevation(at: GridPoint(x: grid.width / 2, y: grid.height / 2)))
        let minimum = grid.elevationsMeters.filter(\.isFinite).min() ?? center
        return (minimum - center) * heightScale - clearance - thickness * 0.5
    }
    nonisolated static func adaptiveSampleIndices(_ count: Int, center requestedCenter: Int? = nil) -> [Int] {
        guard count > 400 else { return Array(0..<count) }
        let center = min(count - 1, max(0, requestedCenter ?? (count - 1) / 2))
        return (0..<count).filter { abs($0 - center) <= 150 || $0 % 3 == 0 || $0 == count - 1 }
    }

    static func makeMesh(
        grid: TerrainGrid,
        widthMeters: Float,
        depthMeters: Float,
        heightScale: Float,
        verticalOffsetMeters: Float = 0,
        circularRadiusMeters: Float? = nil,
        adaptiveNativeDetail: Bool = false,
        detailCenter: GridPoint? = nil
    ) throws -> MeshResource {
        let data = makeMeshData(grid: grid, widthMeters: widthMeters, depthMeters: depthMeters, heightScale: heightScale, verticalOffsetMeters: verticalOffsetMeters, circularRadiusMeters: circularRadiusMeters, adaptiveNativeDetail: adaptiveNativeDetail, detailCenter: detailCenter)
        return try makeMeshResource(data)
    }

    nonisolated static func makeMeshData(
        grid: TerrainGrid,
        widthMeters: Float,
        depthMeters: Float,
        heightScale: Float,
        verticalOffsetMeters: Float = 0,
        circularRadiusMeters: Float? = nil,
        adaptiveNativeDetail: Bool = false,
        detailCenter: GridPoint? = nil
    ) -> TerrainMeshData {
        var vertices: [SIMD3<Float>] = []
        var textureCoordinates: [SIMD2<Float>] = []
        var normals: [SIMD3<Float>] = []
        vertices.reserveCapacity(grid.width * grid.height)
        textureCoordinates.reserveCapacity(grid.width * grid.height)
        normals.reserveCapacity(grid.width * grid.height)

        let centerHeight = Float(grid.elevation(at: GridPoint(x: grid.width / 2, y: grid.height / 2)))
        let physicalWidth = Float(grid.width - 1) * Float(grid.cellSizeMeters)
        let physicalDepth = Float(grid.height - 1) * Float(grid.cellSizeMeters)
        let horizontalScaleX = widthMeters / physicalWidth
        let horizontalScaleZ = depthMeters / physicalDepth
        // The native grid spans the same footprint as the 3 m grid. Keep every
        // native post near the middle and every third post elsewhere. A single
        // rectilinear mesh shares the vertices at each change of spacing.
        let xs = adaptiveNativeDetail ? adaptiveSampleIndices(grid.width, center: detailCenter?.x) : Array(0..<grid.width)
        let ys = adaptiveNativeDetail ? adaptiveSampleIndices(grid.height, center: detailCenter?.y) : Array(0..<grid.height)
        for y in ys {
            for x in xs {
                let normalizedX = Float(x) / Float(grid.width - 1) - 0.5
                let normalizedY = Float(y) / Float(grid.height - 1) - 0.5
                let point = GridPoint(x: x, y: y)
                let elevation = Float(grid.elevation(at: point))
                vertices.append(SIMD3(
                    normalizedX * widthMeters,
                    (elevation - centerHeight) * heightScale + verticalOffsetMeters,
                    normalizedY * depthMeters
                ))
                // Both the source DTM and registered orthophoto are north-up:
                // row zero maps to the top of the image (v = 0).
                textureCoordinates.append(SIMD2(normalizedX + 0.5, normalizedY + 0.5))

                let left = grid.elevation(at: GridPoint(x: max(0, x - 1), y: y))
                let right = grid.elevation(at: GridPoint(x: min(grid.width - 1, x + 1), y: y))
                let up = grid.elevation(at: GridPoint(x: x, y: max(0, y - 1)))
                let down = grid.elevation(at: GridPoint(x: x, y: min(grid.height - 1, y + 1)))
                let xSpan = x == 0 || x == grid.width - 1 ? grid.cellSizeMeters : 2 * grid.cellSizeMeters
                let zSpan = y == 0 || y == grid.height - 1 ? grid.cellSizeMeters : 2 * grid.cellSizeMeters
                let slopeX = Float((right - left) / xSpan) * heightScale / horizontalScaleX
                let slopeZ = Float((down - up) / zSpan) * heightScale / horizontalScaleZ
                normals.append(simd_normalize(SIMD3(-slopeX, 1, -slopeZ)))
            }
        }

        let radius = circularRadiusMeters ?? min(widthMeters, depthMeters) * 0.5
        // Clip only boundary triangles against a fine regular polygon. Interior
        // triangles retain the original DEM vertices and UV registration.
        let sides = 256
        let apothem = radius * cos(Float.pi / Float(sides))
        let clipsFootprint = radius < hypot(widthMeters * 0.5, depthMeters * 0.5)
        var indices: [UInt32] = []
        indices.reserveCapacity((xs.count - 1) * (ys.count - 1) * 6)

        func emitClipped(_ triangle: [UInt32]) {
            struct Vertex {
                var position: SIMD3<Float>
                var normal: SIMD3<Float>
                var uv: SIMD2<Float>
            }
            var polygon = triangle.map { Vertex(position: vertices[Int($0)], normal: normals[Int($0)], uv: textureCoordinates[Int($0)]) }
            for side in 0..<sides {
                let angle = (Float(side) + 0.5) * 2 * Float.pi / Float(sides)
                let normal = SIMD2<Float>(cos(angle), sin(angle))
                func signedDistance(_ v: Vertex) -> Float { simd_dot(SIMD2(v.position.x, v.position.z), normal) - apothem }
                guard !polygon.isEmpty else { return }
                var clipped: [Vertex] = []
                var previous = polygon[polygon.count - 1]
                var previousDistance = signedDistance(previous)
                for current in polygon {
                    let currentDistance = signedDistance(current)
                    if (currentDistance <= 0) != (previousDistance <= 0) {
                        let t = previousDistance / (previousDistance - currentDistance)
                        clipped.append(Vertex(position: previous.position + (current.position - previous.position) * t,
                                              normal: simd_normalize(previous.normal + (current.normal - previous.normal) * t),
                                              uv: previous.uv + (current.uv - previous.uv) * t))
                    }
                    if currentDistance <= 0 { clipped.append(current) }
                    previous = current
                    previousDistance = currentDistance
                }
                polygon = clipped
            }
            guard polygon.count >= 3 else { return }
            let start = UInt32(vertices.count)
            for vertex in polygon {
                vertices.append(vertex.position)
                normals.append(vertex.normal)
                textureCoordinates.append(vertex.uv)
            }
            for i in 1..<(polygon.count - 1) {
                indices.append(contentsOf: [start, start + UInt32(i), start + UInt32(i + 1)])
            }
        }

        for row in 0..<(ys.count - 1) {
            for column in 0..<(xs.count - 1) {
                let topLeft = UInt32(row * xs.count + column)
                let topRight = topLeft + 1
                let bottomLeft = topLeft + UInt32(xs.count)
                let bottomRight = bottomLeft + 1
                let corners = [topLeft, topRight, bottomLeft, bottomRight]
                if !clipsFootprint || corners.allSatisfy({ index in
                    let p = vertices[Int(index)]
                    return p.x * p.x + p.z * p.z <= apothem * apothem
                }) {
                    indices.append(contentsOf: [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight])
                    continue
                }
                let p0 = vertices[Int(topLeft)], p1 = vertices[Int(bottomRight)]
                let nearestX = max(p0.x, min(0, p1.x))
                let nearestZ = max(p0.z, min(0, p1.z))
                guard nearestX * nearestX + nearestZ * nearestZ < radius * radius else { continue }
                emitClipped([topLeft, bottomLeft, topRight])
                emitClipped([topRight, bottomLeft, bottomRight])
            }
        }

        return TerrainMeshData(vertices: vertices, normals: normals, textureCoordinates: textureCoordinates, indices: indices)
    }

    static func makeMeshResource(_ data: TerrainMeshData) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: "HiRISE terrain surface")
        descriptor.positions = MeshBuffers.Positions(data.vertices)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(data.textureCoordinates)
        descriptor.normals = MeshBuffers.Normals(data.normals)
        descriptor.primitives = .triangles(data.indices)
        descriptor.materials = .allFaces(0)
        return try MeshResource.generate(from: [descriptor])
    }

    static func makeSlopeOverlayMesh(
        grid: TerrainGrid,
        widthMeters: Float,
        depthMeters: Float,
        heightScale: Float,
        liftMeters: Float,
        circularRadiusMeters: Float? = nil
    ) throws -> MeshResource {
        try makeMesh(
            grid: grid,
            widthMeters: widthMeters,
            depthMeters: depthMeters,
            heightScale: heightScale,
            verticalOffsetMeters: liftMeters,
            circularRadiusMeters: circularRadiusMeters
        )
    }

    static func makeSlopeTexture(grid: TerrainGrid) throws -> CGImage {
        let width = grid.width
        let height = grid.height
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        for y in 0..<height {
            for x in 0..<width {
                let left = grid.elevation(at: GridPoint(x: max(0, x - 1), y: y))
                let right = grid.elevation(at: GridPoint(x: min(width - 1, x + 1), y: y))
                let up = grid.elevation(at: GridPoint(x: x, y: max(0, y - 1)))
                let down = grid.elevation(at: GridPoint(x: x, y: min(height - 1, y + 1)))
                let xSpan = x == 0 || x == width - 1 ? grid.cellSizeMeters : 2 * grid.cellSizeMeters
                let ySpan = y == 0 || y == height - 1 ? grid.cellSizeMeters : 2 * grid.cellSizeMeters
                let slopeDegrees = atan(hypot((right - left) / xSpan, (down - up) / ySpan)) * 180 / .pi

                let red: UInt8
                let green: UInt8
                let blue: UInt8
                let alpha: UInt8
                if slopeDegrees < 7 {
                    (red, green, blue, alpha) = (65, 178, 128, 94)
                } else if slopeDegrees < 14 {
                    (red, green, blue, alpha) = (230, 171, 61, 122)
                } else {
                    (red, green, blue, alpha) = (225, 75, 62, 150)
                }

                let offset = (y * width + x) * bytesPerPixel
                let opacity = Float(alpha) / 255
                pixels[offset] = UInt8(Float(red) * opacity)
                pixels[offset + 1] = UInt8(Float(green) * opacity)
                pixels[offset + 2] = UInt8(Float(blue) * opacity)
                pixels[offset + 3] = alpha
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let context = pixels.withUnsafeMutableBufferPointer({ buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * bytesPerPixel,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        }), let image = context.makeImage() else {
            throw MarsDataCatalog.CatalogError.couldNotBuildSlopeOverlay
        }
        return image
    }

    static func makeHorizonSkirt(
        grid: TerrainGrid,
        innerWidthMeters: Float,
        innerDepthMeters: Float,
        ringWidthsMeters: [Float] = [350, 1_200, 24_000],
        adaptiveNativeDetail: Bool = false,
        detailCenter: GridPoint? = nil,
        aerialPitch: Float = 0
    ) throws -> MeshResource {
        _ = adaptiveNativeDetail
        _ = detailCenter
        let data = makeHorizonSkirtData(grid: grid, innerWidthMeters: innerWidthMeters,
                                        innerDepthMeters: innerDepthMeters, ringWidthsMeters: ringWidthsMeters,
                                        aerialPitch: aerialPitch)
        var descriptor = MeshDescriptor(name: "synthetic circular Mars horizon")
        var accumulatedNormals = Array(repeating: SIMD3<Float>.zero, count: data.vertices.count)
        for offset in stride(from: 0, to: data.indices.count, by: 3) {
            let ia = Int(data.indices[offset])
            let ib = Int(data.indices[offset + 1])
            let ic = Int(data.indices[offset + 2])
            let normal = simd_cross(data.vertices[ib] - data.vertices[ia], data.vertices[ic] - data.vertices[ia])
            accumulatedNormals[ia] += normal
            accumulatedNormals[ib] += normal
            accumulatedNormals[ic] += normal
        }
        let normals = accumulatedNormals.map { normal -> SIMD3<Float> in
            guard simd_length_squared(normal) > 1e-12 else { return SIMD3<Float>(0, 1, 0) }
            return simd_normalize(normal)
        }
        descriptor.positions = MeshBuffers.Positions(data.vertices)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(data.indices)
        descriptor.materials = .allFaces(0)
        return try MeshResource.generate(from: [descriptor])
    }

    /// Circular terrain skirts meet the measured crop at its circular edge and
    /// continue as explicitly synthetic, low-detail topography to the horizon.
    nonisolated static func makeHorizonSkirtData(
        grid: TerrainGrid,
        innerWidthMeters: Float,
        innerDepthMeters: Float,
        ringWidthsMeters: [Float] = [350, 1_200, 24_000],
        angularSegments: Int = 256,
        aerialPitch: Float = 0
    ) -> HorizonSkirtMeshData {
        let baseRadius = min(innerWidthMeters, innerDepthMeters) * 0.5
        let rings = [baseRadius] + ringWidthsMeters.map { baseRadius + max(1, $0) }
        let centerElevation = Float(grid.elevation(at: GridPoint(x: grid.width / 2, y: grid.height / 2)))
        let segmentCount = max(32, angularSegments)
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(rings.count * segmentCount)
        indices.reserveCapacity((rings.count - 1) * segmentCount * 6)

        for (ringIndex, radius) in rings.enumerated() {
            for sampleIndex in 0..<segmentCount {
                let angle = Float(sampleIndex) / Float(segmentCount) * 2 * .pi
                let x = cos(angle) * radius
                let z = sin(angle) * radius
                let xGrid = max(0, min(grid.width - 1,
                    Int((Float(grid.width - 1) * 0.5 + x / innerWidthMeters * Float(grid.width - 1)).rounded())))
                let yGrid = max(0, min(grid.height - 1,
                    Int((Float(grid.height - 1) * 0.5 + z / innerDepthMeters * Float(grid.height - 1)).rounded())))
                let edgeHeight = Float(grid.elevation(at: GridPoint(x: xGrid, y: yGrid))) - centerElevation
                let radialDistance = radius - baseRadius
                let transitionWidth = max(1, ringWidthsMeters.first ?? 3_000)
                let blend = min(1, max(0, radialDistance / transitionWidth))
                let curvatureDrop = (radius * radius - baseRadius * baseRadius) / (2 * 3_389_500)
                // Broad, deterministic ridges are synthetic scenery, not measured relief.
                let ridge = (sin(angle * 4 + Float(ringIndex) * 0.7) * 16
                    + sin(angle * 9 - Float(ringIndex) * 0.45) * 6) * min(1, radialDistance / 350)
                // Level the distant skirt after the aerial world is pitched,
                // smoothly preserving the exact measured edge.
                let pitchCompensation = -tan(aerialPitch) * z * blend
                vertices.append(SIMD3(x, edgeHeight * (1 - blend) - curvatureDrop + ridge + pitchCompensation, z))
            }
        }

        for ring in 0..<(rings.count - 1) {
            let innerBase = UInt32(ring * segmentCount)
            let outerBase = innerBase + UInt32(segmentCount)
            for index in 0..<segmentCount {
                let next = (index + 1) % segmentCount
                let inner = innerBase + UInt32(index)
                let innerNext = innerBase + UInt32(next)
                let outer = outerBase + UInt32(index)
                let outerNext = outerBase + UInt32(next)
                // Consistent upward-facing winding across the closed annulus.
                indices.append(contentsOf: [inner, innerNext, outer, innerNext, outerNext, outer])
            }
        }
        return HorizonSkirtMeshData(vertices: vertices, indices: indices)
    }

}
