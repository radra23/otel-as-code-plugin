FROM apache/spark:3.5.1

COPY target/nightly-aggregation-1.0.0.jar /opt/spark/jars/nightly-aggregation.jar

ENTRYPOINT ["/opt/spark/bin/spark-submit", "--class", "com.example.batch.NightlyAggregation", \
            "/opt/spark/jars/nightly-aggregation.jar"]
