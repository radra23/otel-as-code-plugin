from django.urls import path

from orders import views

urlpatterns = [
    path("orders/<int:order_id>", views.order_detail),
    path("healthz", views.healthz),
]
