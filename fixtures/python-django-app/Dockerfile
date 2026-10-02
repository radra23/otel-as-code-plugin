FROM python:3.12-slim
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir .
# Production imports shop/wsgi.py, not manage.py: that is the file instrumentation must reach.
CMD ["gunicorn", "shop.wsgi:application", "--bind", "0.0.0.0:8000"]
