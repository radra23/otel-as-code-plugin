from setuptools import find_packages, setup

setup(
    name="orders-api",
    version="0.2.0",
    packages=find_packages(),
    install_requires=["flask>=3.0"],
    entry_points={"console_scripts": ["orders-api=orders_api.app:main"]},
)
