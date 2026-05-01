FROM quay.io/jupyter/scipy-notebook:2024-09-02

# Pre-install DB connectors so the NetworkPolicy can block all outbound internet
# after pod start. Without this, pip install at runtime would need port 443 egress.
RUN pip install --no-cache-dir \
    pymysql==1.1.1 \
    "pymongo>=3.12,<4.0" \
    clickhouse-connect==0.8.14
