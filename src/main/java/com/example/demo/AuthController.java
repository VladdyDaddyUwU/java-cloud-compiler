package com.example.demo;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpSession;

import java.util.Optional;

@RestController
@RequestMapping("/api/auth")
public class AuthController {

    private final UserRepository userRepository;
    private final PasswordEncoder passwordEncoder;

    // Spring injects these automatically (constructor injection)
    public AuthController(UserRepository userRepository, PasswordEncoder passwordEncoder) {
        this.userRepository = userRepository;
        this.passwordEncoder = passwordEncoder;
    }

    @PostMapping("/signup")
    public ResponseEntity<String> signup(@RequestBody AuthRequest request) {
        // Reject if username already taken
        if (userRepository.existsByUsername(request.getUsername())) {
            return ResponseEntity.status(HttpStatus.CONFLICT).body("Username already taken");
        }

        // Hash the password before storing. Never store the raw password
        String hashed = passwordEncoder.encode(request.getPassword());
        User user = new User(request.getUsername(), hashed);
        userRepository.save(user);

        return ResponseEntity.status(HttpStatus.CREATED).body("User registered: " + user.getUsername());
    }

    @PostMapping("/login")
    public ResponseEntity<String> login(@RequestBody AuthRequest request, HttpServletRequest httpRequest) {
        Optional<User> found = userRepository.findByUsername(request.getUsername());

        // Verify the user exists AND the password matches the stored hash
        if (found.isEmpty() || !passwordEncoder.matches(request.getPassword(), found.get().getPasswordHash())) {
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body("Invalid username or password");
        }

        // Establish a session (session-based auth)
        HttpSession session = httpRequest.getSession(true);
        session.setAttribute("username", found.get().getUsername());

        return ResponseEntity.ok("Login successful for " + found.get().getUsername());
    }
}