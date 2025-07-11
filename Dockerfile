# Use an official Node.js runtime as a parent image (Alpine version for smaller size)
FROM node:18-alpine

# Set the working directory in the container
WORKDIR /usr/src/app

# If we had a package.json, we would copy it and run npm install
# For now, these are placeholders. If you add dependencies later, uncomment and create package.json.
# COPY package*.json ./
# RUN npm install --only=production

# Copy the application source code and necessary files to the working directory
COPY server.js ./
COPY authorized_receiver_accounts.json ./

# Make port 3000 available to the world outside this container
EXPOSE 3000

# Define environment variables if needed (e.g., for port, though it's hardcoded in server.js now)
# ENV NODE_ENV=production
# ENV PORT=3000

# Run server.js when the container launches
CMD [ "node", "server.js" ]
