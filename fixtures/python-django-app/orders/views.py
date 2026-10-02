from django.http import JsonResponse


def order_detail(request, order_id):
    return JsonResponse({"id": order_id, "status": "open"})


def healthz(request):
    return JsonResponse({"ok": True})
