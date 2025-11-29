from django.contrib.auth.mixins import LoginRequiredMixin
from django.views.generic import TemplateView


class VersionInfotemplateView(LoginRequiredMixin, TemplateView):
    template_name = "version_info/info.html"
