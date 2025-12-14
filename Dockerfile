# 1. Use Python 3.10
FROM python:3.10-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DEBUG=False \
    SECRET_KEY=changeme \
    ALLOWED_HOSTS=*

# 2. Install System Dependencies (Includes gnupg2 for keys)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential \
       libpq-dev \
       libjpeg-dev \
       zlib1g-dev \
       curl \
       gnupg2 \
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

# 2.5. INSTALL AZURE DRIVERS (Fixed for Debian 12)
# We use 'gpg' instead of 'apt-key' to avoid build errors.
RUN curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
    && curl https://packages.microsoft.com/config/debian/12/prod.list > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y msodbcsql18 unixodbc-dev

WORKDIR /app

# 3. Copy files
COPY . /app/

# 4. Install Dependencies (Includes mssql-django)
RUN pip install --upgrade pip setuptools wheel && \
    pip install --no-cache-dir -r requirements.txt uvicorn[standard] psycopg2-binary gunicorn dj-database-url mssql-django pyodbc

# 5. CONFIGURE DATABASE SETTINGS (Robust Logic)
# - 'default': Connects to Railway Postgres (Safe fallback to SQLite during build)
# - 'erp_data': Connects to Azure SQL (Safe fallback to SQLite if variable missing)
RUN printf "from .base import *\n\
import dj_database_url\n\
import os\n\
\n\
# 1. Main Database (Postgres)\n\
db_url = os.environ.get('DATABASE_URL', '')\n\
if not db_url:\n\
    default_config = {'ENGINE': 'django.db.backends.sqlite3', 'NAME': 'db.sqlite3'}\n\
else:\n\
    default_config = dj_database_url.parse(db_url, conn_max_age=600)\n\
\n\
# 2. Azure Database (ERP Data)\n\
azure_url = os.environ.get('AZURE_SQL_URL', '')\n\
if not azure_url:\n\
    erp_config = {'ENGINE': 'django.db.backends.sqlite3', 'NAME': 'erp_fallback.sqlite3'}\n\
else:\n\
    erp_config = dj_database_url.parse(azure_url)\n\
\n\
DATABASES = {\n\
    'default': default_config,\n\
    'erp_data': erp_config\n\
}\n\
\n\
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

# 7. Create .env file template
RUN echo "DEBUG=$DEBUG" > .env && \
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