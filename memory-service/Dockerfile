FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY memory.py app.py ./

EXPOSE 8080
# IRIS_HOST / IRIS_STORE_ID / IRIS_API_KEY injected at deploy time (never baked in).
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
