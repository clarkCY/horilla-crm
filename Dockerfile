# 1. Use Python 3.10
FROM python:3.10-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DATABASE_URL="" \
    DEBUG=False \
    SECRET_KEY=changeme \
    ALLOWED_HOSTS=*

# 2. Install System Dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential \
       libpq-dev \
       libjpeg-dev \
       zlib1g-dev \
       curl \
       netcat-openbsd \
       git \
       libcairo2-dev \
       pkg-config \
       libpango-1.0-0 \
       libpangoft2-1.0-0 \
       libgdk-pixbuf-2.0-0 \
       libffi-dev \
       shared-mime-info \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 3. Copy files
COPY . /app/

# 4. FIX: Install dj-database-url explicitly
# We add this to ensure we can parse the Railway DATABASE_URL
RUN pip install --upgrade pip setuptools wheel && \
    pip install --no-cache-dir -r requirements.txt uvicorn[standard] psycopg2-binary gunicorn dj-database-url

# 5. FIX: Configure Settings to FORCE PostgreSQL
# We inject code to read the DATABASE_URL variable
RUN printf "from .base import *\n\
import dj_database_url\n\
import os\n\
DATABASES = {'default': dj_database_url.config(default=os.environ.get('DATABASE_URL'), conn_max_age=600)}\n\
CSRF_TRUSTED_ORIGINS = ['https://*.railway.app', 'https://*.up.railway.app']\n\
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')\n" > horilla/settings/local_settings.py

# 6. Admin Creation Script
RUN echo "import os" > /app/create_admin.py && \
    echo "import django" >> /app/create_admin.py && \
    echo "os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'horilla.settings')" >> /app/create_admin.py && \
    echo "from django.contrib.auth import get_user_model" >> /app/create_admin.py && \
    echo "django.setup()" >> /app/create_admin.py && \
    echo "User = get_user_model()" >> /app/create_admin.py && \
    echo "if not User.objects.filter(username='admin').exists():" >> /app/create_admin.py && \
    echo "    User.objects.create_superuser('admin', 'admin@example.com', 'admin123')" >> /app/create_admin.py && \
    echo "    print('Superuser admin created')" >> /app/create_admin.py

# 7. Create .env file
RUN echo "DATABASE_URL=$DATABASE_URL" > .env && \
    echo "DEBUG=$DEBUG" >> .env && \
    echo "SECRET_KEY=$SECRET_KEY" >> .env && \
    echo "ALLOWED_HOSTS=$ALLOWED_HOSTS" >> .env

# 8. Entrypoint
RUN echo '#!/bin/bash' > /entrypoint.sh && \
    echo 'set -e' >> /entrypoint.sh && \
    echo 'python manage.py migrate' >> /entrypoint.sh && \
    echo 'python manage.py collectstatic --noinput' >> /entrypoint.sh && \
    echo 'python /app/create_admin.py' >> /entrypoint.sh && \
    echo 'exec "$@"' >> /entrypoint.sh && \
    chmod +x /entrypoint.sh

# 9. User setup
RUN useradd --create-home --uid 1000 appuser && \
    mkdir -p staticfiles media && \
    chown -R appuser:appuser /app /entrypoint.sh

USER appuser

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]

CMD sh -c "uvicorn horilla.asgi:application --host 0.0.0.0 --port ${PORT:-8000}"