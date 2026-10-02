import os

SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "dev-only")
DEBUG = os.environ.get("DJANGO_DEBUG") == "1"
ALLOWED_HOSTS = ["*"]
ROOT_URLCONF = "shop.urls"
INSTALLED_APPS = ["orders"]
MIDDLEWARE = ["django.middleware.common.CommonMiddleware"]
WSGI_APPLICATION = "shop.wsgi.application"
