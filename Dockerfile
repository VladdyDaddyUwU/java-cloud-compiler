FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app

COPY pom.xml .
RUN mvn dependency:go-offline

# Copies the source and builds the fat JAR
COPY src ./src
RUN mvn clean package -DskipTests

#  Stage 2: Runtime image 
FROM eclipse-temurin:21-jre
WORKDIR /app

# Copies ONLY the finished JAR out of the build stage
COPY --from=build /app/target/*.jar app.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]