import AppKit
import CoreImage
import ImageIO
import Foundation

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: prepare_hirise_ortho.swift input.jpg output.jpg")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CIImage(contentsOf: input) else { fatalError("Unable to read crop") }
let exposed = source.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.20])
let contrasted = exposed.applyingFilter("CIColorControls", parameters: [
    kCIInputContrastKey: 1.04,
    kCIInputSaturationKey: 0.025,
    kCIInputBrightnessKey: 0.025,
])
let display = contrasted.applyingFilter("CIColorMatrix", parameters: [
    "inputRVector": CIVector(x: 0.96, y: 0, z: 0, w: 0),
    "inputGVector": CIVector(x: 0.67, y: 0, z: 0, w: 0),
    "inputBVector": CIVector(x: 0.42, y: 0, z: 0, w: 0),
    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
    "inputBiasVector": CIVector(x: 0.018, y: 0.012, z: 0.006, w: 0),
])
let context = CIContext(options: [.useSoftwareRenderer: false])
guard let image = context.createCGImage(display, from: display.extent) else {
    fatalError("Unable to render the display stretch")
}
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.jpeg" as CFString, 1, nil) else {
    fatalError("Unable to create JPEG destination")
}
CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fatalError("Unable to save display image") }
