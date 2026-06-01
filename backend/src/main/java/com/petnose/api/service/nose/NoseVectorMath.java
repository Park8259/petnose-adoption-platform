package com.petnose.api.service.nose;

import java.util.ArrayList;
import java.util.List;

public final class NoseVectorMath {

    private NoseVectorMath() {
    }

    public static double dot(List<Double> left, List<Double> right) {
        validateSameDimension(left, right);

        double sum = 0.0;
        for (int i = 0; i < left.size(); i++) {
            sum += left.get(i) * right.get(i);
        }
        return sum;
    }

    public static List<Double> normalize(List<Double> vector) {
        validateVector(vector);

        double normSquared = 0.0;
        for (Double value : vector) {
            normSquared += value * value;
        }

        double norm = Math.sqrt(normSquared);
        if (norm == 0.0) {
            throw new IllegalArgumentException("Vector norm must not be zero.");
        }

        List<Double> normalized = new ArrayList<>(vector.size());
        for (Double value : vector) {
            normalized.add(value / norm);
        }
        return normalized;
    }

    public static List<Double> centroid(List<List<Double>> vectors) {
        validateVectors(vectors);

        int dimension = vectors.get(0).size();
        double[] sums = new double[dimension];
        for (List<Double> vector : vectors) {
            for (int i = 0; i < dimension; i++) {
                sums[i] += vector.get(i);
            }
        }

        List<Double> mean = new ArrayList<>(dimension);
        for (double sum : sums) {
            mean.add(sum / vectors.size());
        }
        return normalize(mean);
    }

    public static void validateSameDimension(List<Double> left, List<Double> right) {
        validateVector(left);
        validateVector(right);

        if (left.size() != right.size()) {
            throw new IllegalArgumentException("Vector dimensions must match.");
        }
    }

    public static void validateVectors(List<List<Double>> vectors) {
        if (vectors == null || vectors.isEmpty()) {
            throw new IllegalArgumentException("Vectors must not be empty.");
        }

        validateVector(vectors.get(0));
        int dimension = vectors.get(0).size();
        for (List<Double> vector : vectors) {
            validateVector(vector);
            if (vector.size() != dimension) {
                throw new IllegalArgumentException("Vector dimensions must match.");
            }
        }
    }

    private static void validateVector(List<Double> vector) {
        if (vector == null || vector.isEmpty()) {
            throw new IllegalArgumentException("Vector must not be empty.");
        }
        if (vector.stream().anyMatch(value -> value == null)) {
            throw new IllegalArgumentException("Vector values must not be null.");
        }
    }
}
