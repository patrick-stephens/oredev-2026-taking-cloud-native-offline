ARG PYTHON_IMAGE=python:3.12.8-slim-bookworm
FROM ${PYTHON_IMAGE}

WORKDIR /app
COPY requirements.txt .
COPY deps/wheels /deps/wheels
RUN pip install --root-user-action=ignore --no-index --find-links /deps/wheels -r requirements.txt
COPY app.py .

EXPOSE 5000
CMD ["python", "-m", "flask", "--app", "app", "run", "--host=0.0.0.0"]
