package com.example.batch;

import org.apache.spark.sql.SparkSession;

public class NightlyAggregation {
    public static void main(String[] args) {
        SparkSession spark = SparkSession.builder()
                .appName("nightly-aggregation")
                .getOrCreate();

        spark.read().parquet("s3a://data/orders/").createOrReplaceTempView("orders");
        spark.sql("SELECT date_trunc('day', created_at), count(*) FROM orders GROUP BY 1")
                .write().parquet("s3a://data/orders-daily/");

        spark.stop();
    }
}
