//
//  DeviceCommandResources.swift
//  Replicould — GameModels
//
//  The mineable resource vocabulary. It lives at the model tier because two
//  feature modules need it — the device inspector's mine/retarget parameter
//  panels and the directive composer's transport requirement/priority editors —
//  and duplicating the list in both would let them drift.
//

import Foundation

/// The resource types a device can mine, in the backend's canonical order.
public enum MiningResource {
    public static let all: [String] = [
        "structural", "conductive", "silicates", "carbon", "volatiles", "rares",
    ]
}
