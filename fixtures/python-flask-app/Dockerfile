FROM python:3.12-slim
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir .
# Application factory: there is no module-level `app`, so the instrumentor belongs inside create_app().
CMD ["gunicorn", "orders:create_app()", "--bind", "0.0.0.0:8000"]
