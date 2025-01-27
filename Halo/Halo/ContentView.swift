//
//  ContentView.swift
//  Halo
//
//  Created by Yannis De Cleene on 20/01/2025.
//

import SwiftUI
import AccessorySetupKit

struct ContentView: View {
    @State var ringSessionManager = RingSessionManager()
    @State var batteryInfo: BatteryInfo?
    @State private var data: [HeartRateDataPoint] = []
    
    var body: some View {
        List {
            Section("MY DEVICE", content: {
                if ringSessionManager.pickerDismissed, let currentRing = ringSessionManager.currentRing {
                    VStack {
                        makeRingView(ring: currentRing)
                    }
                } else {
                    Button {
                        ringSessionManager.presentPicker()
                    } label: {
                        Text("Add Ring")
                            .frame(maxWidth: .infinity)
                            .font(Font.headline.weight(.semibold))
                    }
                }
            })
            
            Section("Increment", content: {
                Button(action: {
                    print("Last CMD_X: \(Counter.shared.CMD_X)")
                    Counter.shared.increment()
                }) {
                    Text("Increment")
                        .frame(maxWidth: .infinity)
                        .font(Font.headline.weight(.semibold))
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            })
            
            Section("Blink Twice", content: {
                Button(action: {
                    ringSessionManager.sendBlinkTwiceCommand()
                }) {
                    Text("Send Blink Twice Command")
                        .frame(maxWidth: .infinity)
                        .font(Font.headline.weight(.semibold))
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            })
            
            Section("X", content: {
                Button(action: {
                    ringSessionManager.sendXCommand()
                }) {
                    Text("Send X Command")
                        .frame(maxWidth: .infinity)
                        .font(Font.headline.weight(.semibold))
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            })
            
            Section("X Log", content: {
                Button(action: {
                    ringSessionManager.getHeartRateLog { hrl in
                        do {
                            let heartRatesWithTimes = try hrl.heartRatesWithTimes()
                            print(heartRatesWithTimes)
                            data = heartRatesWithTimes.map { HeartRateDataPoint(heartRate: $0.0, time: $0.1) }
                        } catch {
                            print("Error loading data: \(error)")
                        }
                    }
                }) {
                    Text("Get Heart Rate Log")
                        .frame(maxWidth: .infinity)
                        .font(Font.headline.weight(.semibold))
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            })
            
            Section("Battery Status", content: {
                Button(action: {
                    ringSessionManager.getBatteryStatus { info in
                        batteryInfo = info
                    }
                }) {
                    Text("Get Battery Status")
                        .frame(maxWidth: .infinity)
                        .font(Font.headline.weight(.semibold))
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                
                if let info = batteryInfo {
                    Text("Battery Level: \(info.batteryLevel)%")
                    Text("Charging: \(info.charging ? "Yes" : "No")")
                }
            })
            
            Section("Heart Rate Log", content: {
                Button(action: {
                    ringSessionManager.getHeartRateLog { hrl in
                        do {
                            let heartRatesWithTimes = try hrl.heartRatesWithTimes()
                            print(heartRatesWithTimes)
                            data = heartRatesWithTimes.map { HeartRateDataPoint(heartRate: $0.0, time: $0.1) }
                        } catch {
                            print("Error loading data: \(error)")
                        }
                    }
                }) {
                    Text("Get Heart Rate Log")
                        .frame(maxWidth: .infinity)
                        .font(Font.headline.weight(.semibold))
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            })
            
            HeartRateGraphView(data: data)
            
            
            Section("Heart Rate", content: {
                Button(action: {
                    ringSessionManager.startRealTimeStreaming(type: .heartRate)
                }) {
                    Text("Start Heart Rate Streaming")
                        .frame(maxWidth: .infinity)
                        .font(Font.headline.weight(.semibold))
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                
                Button(action: {
                    ringSessionManager.continueRealTimeStreaming(type: .heartRate)
                }) {
                    Text("Continue Heart Rate Streaming")
                        .frame(maxWidth: .infinity)
                        .font(Font.headline.weight(.semibold))
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                
                Button(action: {
                    ringSessionManager.stopRealTimeStreaming(type: .heartRate)
                }) {
                    Text("Stop Heart Rate Streaming")
                        .frame(maxWidth: .infinity)
                        .font(Font.headline.weight(.semibold))
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            })
            
            Section("SPO2", content: {
                Button(action: {
                    ringSessionManager.startRealTimeStreaming(type: .spo2)
                }) {
                    Text("Start SPO2 Streaming")
                        .frame(maxWidth: .infinity)
                        .font(Font.headline.weight(.semibold))
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                
                Button(action: {
                    ringSessionManager.continueRealTimeStreaming(type: .spo2)
                }) {
                    Text("Continue SPO2 Streaming")
                        .frame(maxWidth: .infinity)
                        .font(Font.headline.weight(.semibold))
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                
                Button(action: {
                    ringSessionManager.stopRealTimeStreaming(type: .spo2)
                }) {
                    Text("Stop SPO2 Streaming")
                        .frame(maxWidth: .infinity)
                        .font(Font.headline.weight(.semibold))
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            })
            
            
        }
        .listStyle(.insetGrouped)
        
    }
    
    @ViewBuilder
    private func makeRingView(ring: ASAccessory) -> some View {
        HStack {
            Image("colmi")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 70)
            
            VStack(alignment: .leading) {
                Text(ring.displayName)
                    .font(Font.headline.weight(.semibold))
            }
        }
    }
}

#Preview {
    ContentView()
}
