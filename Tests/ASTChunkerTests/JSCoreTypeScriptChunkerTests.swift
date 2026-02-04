//
//  JSCoreTypeScriptChunkerTests.swift
//  ASTChunkerTests
//
//  Tests for JavaScriptCore-based TypeScript/GTS chunker
//

import XCTest
@testable import ASTChunker

final class JSCoreTypeScriptChunkerTests: XCTestCase {
  
  var chunker: JSCoreTypeScriptChunker!
  
  override func setUpWithError() throws {
    chunker = JSCoreTypeScriptChunker.shared
    
    // Skip tests if chunker is not available (bundle not found)
    try XCTSkipUnless(chunker.isAvailable, "JSCoreTypeScriptChunker not available: \(chunker.initError ?? "unknown")")
  }
  
  // MARK: - TypeScript Tests
  
  func testSimpleTypeScriptClass() {
    let source = """
    import { Component } from '@angular/core';
    
    export class UserService {
      private users: User[] = [];
      
      getUser(id: number): User | undefined {
        return this.users.find(u => u.id === id);
      }
    }
    """
    
    let chunks = chunker.chunk(source: source, language: "ts")
    
    XCTAssertFalse(chunks.isEmpty, "Should produce chunks")
    
    // Should have imports chunk
    let imports = chunks.first { $0.constructType == .imports }
    XCTAssertNotNil(imports, "Should have imports chunk")
    
    // Should have class chunk
    let classChunk = chunks.first { $0.constructType == .classDecl }
    XCTAssertNotNil(classChunk, "Should have class chunk")
    XCTAssertEqual(classChunk?.constructName, "UserService")
  }
  
  func testTypeScriptInterface() {
    let source = """
    interface User {
      id: number;
      name: string;
      email?: string;
    }
    
    interface Config {
      apiUrl: string;
      timeout: number;
    }
    """
    
    let chunks = chunker.chunk(source: source, language: "typescript")
    
    XCTAssertGreaterThanOrEqual(chunks.count, 2, "Should have at least 2 interface chunks")
    
    let interfaces = chunks.filter { $0.constructType == .protocolDecl }
    XCTAssertEqual(interfaces.count, 2, "Should have 2 interface chunks")
  }
  
  func testTypeScriptFunction() {
    let source = """
    export function formatDate(date: Date): string {
      return date.toISOString();
    }
    
    const helper = (x: number) => x * 2;
    """
    
    let chunks = chunker.chunk(source: source, language: "ts")
    
    let functions = chunks.filter { $0.constructType == .function }
    XCTAssertEqual(functions.count, 2, "Should have 2 function chunks")
    
    XCTAssertTrue(functions.contains { $0.constructName == "formatDate" })
    XCTAssertTrue(functions.contains { $0.constructName == "helper" })
  }
  
  // MARK: - GTS (Glimmer TypeScript) Tests
  
  func testGTSComponent() {
    let source = """
    import Component from '@glimmer/component';
    import { tracked } from '@glimmer/tracking';
    
    interface Signature {
      Args: { name: string };
    }
    
    export default class Greeting extends Component<Signature> {
      @tracked count = 0;
      
      <template>
        <div class="greeting">
          Hello, {{@name}}!
          <button {{on "click" this.increment}}>
            Clicked {{this.count}} times
          </button>
        </div>
      </template>
      
      increment = () => {
        this.count++;
      };
    }
    """
    
    let chunks = chunker.chunk(source: source, language: "gts")
    
    XCTAssertFalse(chunks.isEmpty, "Should produce chunks")
    
    // Should have class chunk that includes the template
    let classChunk = chunks.first { $0.constructType == .classDecl }
    XCTAssertNotNil(classChunk, "Should have class chunk")
    XCTAssertEqual(classChunk?.constructName, "Greeting")
    
    // The class chunk should contain the template
    XCTAssertTrue(classChunk?.text.contains("<template>") ?? false, "Class chunk should include <template>")
    XCTAssertTrue(classChunk?.text.contains("</template>") ?? false, "Class chunk should include </template>")
  }
  
  // MARK: - JavaScript Tests
  
  func testJavaScriptClass() {
    let source = """
    import express from 'express';
    
    class Router {
      constructor() {
        this.routes = [];
      }
      
      addRoute(path, handler) {
        this.routes.push({ path, handler });
      }
    }
    
    export { Router };
    """
    
    let chunks = chunker.chunk(source: source, language: "js")
    
    let classChunk = chunks.first { $0.constructType == .classDecl }
    XCTAssertNotNil(classChunk, "Should have class chunk")
    XCTAssertEqual(classChunk?.constructName, "Router")
  }
  
  // MARK: - Error Handling Tests
  
  func testInvalidSyntaxFallback() {
    let source = """
    class Broken {
      // Missing closing brace
    """
    
    // Should not crash, should return fallback chunks
    let chunks = chunker.chunk(source: source, language: "ts")
    XCTAssertFalse(chunks.isEmpty, "Should return fallback chunks on parse error")
  }
  
  // MARK: - Line Number Tests
  
  func testAccurateLineNumbers() {
    let source = """
    // Line 1
    // Line 2
    import { foo } from 'bar';
    // Line 4
    // Line 5
    class MyClass {
      // Line 7
      doSomething() {
        return 42;
      }
    }
    """
    
    let chunks = chunker.chunk(source: source, language: "ts")
    
    let classChunk = chunks.first { $0.constructType == .classDecl }
    XCTAssertNotNil(classChunk)
    XCTAssertEqual(classChunk?.startLine, 6, "Class should start at line 6")
    XCTAssertEqual(classChunk?.endLine, 11, "Class should end at line 11")
  }
}
