# Get the light Node JS base image
FROM node:18-alpine

# Set Work Directory
WORKDIR /app

# Copy package.json file first
COPY package.json yarn.lock* package-lock.json* ./

# Install production dependencies
RUN npm install --production

#Copy All files and rest of the code into container
COPY . .

# Define command to start the app
CMD ["node","src/index.js"]