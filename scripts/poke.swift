// Drives a debug build of Perch: swift scripts/poke.swift <command>
// Commands: expand, collapse, close, tasks, focustab, focus, schedules, settings:<tab>, remind[:start], pass[:bundle id],
//           drop[:over|:launch|:end], airdrop[:sent|:failed]
import Foundation

let command = CommandLine.arguments.dropFirst().first ?? ""
DistributedNotificationCenter.default().postNotificationName(.init("app.perch.debug"), object: command, userInfo: nil, deliverImmediately: true)
