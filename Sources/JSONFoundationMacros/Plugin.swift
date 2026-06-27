//
//  Plugin.swift
//  JSONFoundationMacros
//
//  Compiler-plugin entry point for JSONFoundation's macros.
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct JSONFoundationMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SchemaMacro.self
    ]
}
