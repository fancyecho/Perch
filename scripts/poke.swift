// Drives a debug build of Perch: swift scripts/poke.swift <command>
// Commands: expand, collapse, page:status, page:main, status, close, tasks, focustab, focus, schedules, settings:<tab>, alert, pass[:bundle id]
import Foundation

let command = CommandLine.arguments.dropFirst().first ?? ""
DistributedNotificationCenter.default().postNotificationName(.init("app.perch.debug"), object: command, userInfo: nil, deliverImmediately: true)
