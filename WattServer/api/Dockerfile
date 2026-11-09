FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -q --root-user-action=ignore -r requirements.txt
COPY main.py telegram.py grid_load.py ./
RUN install -d -o nobody -g nogroup /data
USER nobody
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
