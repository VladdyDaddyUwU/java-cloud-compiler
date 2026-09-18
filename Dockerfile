FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app

COPY pom.xml .
RUN mvn dependency:go-offline

# Now copy the source and build the fat JAR
COPY src ./src
RUN mvn clean package -DskipTests

# ---- Stage 2: Runtime image ----
FROM eclipse-temurin:21-jre
WORKDIR /app

# Copy ONLY the finished JAR out of the build stage
COPY --from=build /app/target/*.jar app.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]