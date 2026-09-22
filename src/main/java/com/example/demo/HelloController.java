package com.example.demo;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {

    @GetMapping("/api/status")
    public String hello() {
        return "Java Cloud Compiler API is running!";
    }
}