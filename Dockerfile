# Get the light Node JS base image
FROM node:alpine

# Set Work Directory
WORKDIR /app

# Copy package.json file first
COPY package.json yarn.lock ./

# Install production dependencies
RUN yarn install --production

#Copy All files and rest of the code into container
COPY . .

# Define command to start the app
CMD ["node","src/index.js"]