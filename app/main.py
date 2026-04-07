import os
import platform
from flask import Flask, jsonify
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from prometheus_flask_exporter import PrometheusMetrics
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__)

# Rate limiting — security best practice
limiter = Limiter(
    get_remote_address,
    app=app,
    default_limits=["100 per minute"],
)

# Prometheus metrics — exposes /metrics endpoint automatically
metrics = PrometheusMetrics(app)
metrics.info("app_info", "Application info", version="1.0.0")

APP_ENV = os.getenv("APP_ENV", "production")


@app.route("/")
def index():
    return jsonify({
        "service": "devsecops-api",
        "status": "running",
        "env": APP_ENV,
    })


@app.route("/health")
def health():
    """Health check endpoint — used by load balancers and monitoring."""
    return jsonify({
        "status": "healthy",
        "checks": {
            "api": "ok",
        }
    }), 200


@app.route("/info")
def info():
    """System info — demonstrates what Prometheus can scrape."""
    return jsonify({
        "python_version": platform.python_version(),
        "os": platform.system(),
        "hostname": platform.node(),
        "arch": platform.machine(),
    })


@app.route("/data")
@limiter.limit("30 per minute")
def data():
    """Sample data endpoint — gives OWASP ZAP something real to test."""
    items = [
        {"id": 1, "name": "Item A", "value": 42},
        {"id": 2, "name": "Item B", "value": 99},
        {"id": 3, "name": "Item C", "value": 17},
    ]
    return jsonify({"count": len(items), "items": items})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)