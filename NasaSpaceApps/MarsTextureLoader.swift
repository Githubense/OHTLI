import RealityKit
import UIKit

@MainActor
struct MarsSkyAssets {
    let texture: TextureResource
    let environment: EnvironmentResource
}

/// Loads image-set assets through UIKit, then creates a mipmapped, compressed GPU texture.
@MainActor
enum MarsTextureLoader {
    static func loadAsset(named name: String) async -> TextureResource? {
        guard let image = UIImage(named: name), let cgImage = image.cgImage else {
            NSLog("Mars texture asset missing or not decodable: %@", name)
            return nil
        }

        do {
            let texture = try await TextureResource(
                image: cgImage,
                withName: name,
                options: .init(semantic: .color, compression: .default)
            )
            return texture
        } catch {
            NSLog("Mars texture asset failed to load (%@): %@", name, String(describing: error))
            return nil
        }
    }

    static func loadSky(named name: String) async -> MarsSkyAssets? {
        guard let image = UIImage(named: name), let cgImage = image.cgImage else {
            NSLog("Mars sky asset missing or not decodable: %@", name)
            return nil
        }

        do {
            let texture = try await TextureResource(
                image: cgImage,
                withName: "\(name)-sky-texture",
                options: .init(semantic: .color, compression: .default)
            )
            let environment = try await EnvironmentResource(
                equirectangular: cgImage,
                options: .init(samplingQuality: .fast, specularCubeDimension: 128, compression: .default)
            )
            return MarsSkyAssets(texture: texture, environment: environment)
        } catch {
            NSLog("Mars sky environment failed to load (%@): %@", name, String(describing: error))
            return nil
        }
    }
}
